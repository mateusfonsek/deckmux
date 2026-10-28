import AppKit
import DeckmuxTop
import SwiftUI

/// The "Gerenciador de tarefas" window. One per app; reads only
/// while on screen.
@MainActor
final class TaskManagerWindowController: NSWindowController, NSWindowDelegate {
    /// Set at launch; the menu bar item, the Janela menu and the palette open it.
    static var shared: TaskManagerWindowController?

    private let model: TaskManagerModel
    private let reveal: (UUID) -> Void
    private let showMain: () -> Void

    init(deck: Deck, mainWindow: NSWindow?, reveal: @escaping (UUID) -> Void, showMain: @escaping () -> Void) {
        model = TaskManagerModel(deck: deck, mainWindow: mainWindow)
        self.reveal = reveal
        self.showMain = showMain
        let window = TaskManagerWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 632),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                       backing: .buffered, defer: true)
        window.title = "Gerenciador de tarefas"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let actions = TaskManagerRowActions(
            showItem: { [weak self] in self?.showItem($0) },
            showTerminal: { [weak self] in self?.showTerminal($0) },
            endProcesses: { [weak self] in self?.confirmAndEnd($0) },
            activate: { [weak self] row in
                if row.canShowTerminal { self?.showTerminal(row) } else { self?.showItem(row) }
            })
        let hosting = NSHostingController(rootView: TaskManagerView(model: model, actions: actions))
        // Only the minimum comes from SwiftUI; otherwise the window shrinks to it.
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 940, height: 632))
        window.contentMinSize = NSSize(width: 820, height: 480)
        window.center()
        window.setFrameAutosaveName("DeckmuxTaskManager")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(includingProcesses: Bool? = nil) {
        if let includingProcesses { model.includesProcesses = includingProcesses }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.start()
    }

    #if DEBUG
    /// For automated checks: keeps the window above Stage Manager's stages so
    /// it can be captured, and logs the rows as text.
    func exposeForChecks() {
        window?.level = .floating
        window?.collectionBehavior.insert(.canJoinAllSpaces)
        model.logsRows = true
    }
    #endif

    func windowWillClose(_ notification: Notification) {
        model.stop()
    }

    /// Minimized, behind other windows or on another Space: nothing to show,
    /// so nothing to read.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window, window.isVisible else { return }
        if window.occlusionState.contains(.visible) { model.start() } else { model.stop() }
    }

    // MARK: Rows

    private func showItem(_ row: TaskRow) {
        guard let id = row.itemID, let item = model.deck.items.first(where: { $0.id == id }) else { return }
        model.deck.select(item)
        showMain()
    }

    private func showTerminal(_ row: TaskRow) {
        guard let terminal = row.terminalID else { return showItem(row) }
        reveal(terminal)
    }

    /// Asks first; then SIGTERM to the foreground process group (or the row's
    /// root processes) and SIGKILL 3 s later to whatever of them is still there.
    private func confirmAndEnd(_ row: TaskRow) {
        let appPID = Int(getpid())
        let all = row.killableProcessIDs(appPID: appPID)
        guard !all.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = all.count == 1 ? "Encerrar processo?" : "Encerrar processos?"
        alert.informativeText = "\(row.title) · \(TaskFormat.processCount(all.count)). "
            + "Pede para fechar; o que não fechar em 3 segundos é forçado."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Encerrar")
        alert.addButton(withTitle: "Cancelar").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.end(row, appPID: appPID) }
        }
    }

    private func end(_ row: TaskRow, appPID: Int) {
        let groups = row.gracefulGroupIDs(appGroupID: Int(getpgrp()))
        let pids = groups.isEmpty ? row.gracefulProcessIDs(appPID: appPID) : []
        for group in groups { killpg(pid_t(group), SIGTERM) }
        for pid in pids { kill(pid_t(pid), SIGTERM) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            for group in groups where killpg(pid_t(group), 0) == 0 { killpg(pid_t(group), SIGKILL) }
            for pid in pids where kill(pid_t(pid), 0) == 0 { kill(pid_t(pid), SIGKILL) }
            self?.model.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.model.refresh() }
    }
}

/// ⌘W closes it, as in cmux; in the main window ⌘W belongs to the terminal.
private final class TaskManagerWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
