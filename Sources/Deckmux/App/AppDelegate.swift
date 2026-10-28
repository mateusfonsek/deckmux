import AppKit
import GhosttyKit
import OSLog
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static let logger = Logger(subsystem: "dev.fonsek.deckmux", category: "app")

    let ghostty: Ghostty.App
    let undoManager = ExpiringUndoManager()
    let workspaces: WorkspaceStore
    private var mainWindow: MainWindowController?
    private var claudeHooks: ClaudeHookCenter?
    private var statusItem: AgentStatusItem?
    private var hotkey: GlobalHotkey?
    private var monitor: MonitorPanelController?
    private var autosaveTimer: Timer?
    private var autosaveTicks = 0
    private var appearanceObservation: NSKeyValueObservation?

    override init() {
        GhosttyEnvironment.configure()
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            Self.logger.critical("ghostty_init failed")
        }
        ghostty = Ghostty.App()
        // main.swift creates the delegate on the main thread.
        workspaces = MainActor.assumeIsolated { WorkspaceStore() }
        super.init()
        ghostty.delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        guard ghostty.app != nil else {
            Self.logger.critical("Ghostty app is not ready: \(self.ghostty.readiness.rawValue, privacy: .public)")
            return
        }
        observeAppearance()
        let window = MainWindowController(ghostty: ghostty, workspaces: workspaces)
        mainWindow = window
        let hooks = ClaudeHookCenter(deck: window.deck)
        claudeHooks = hooks
        hooks.start()
        let status = AgentStatusItem(deck: window.deck, meetings: window.nextMeeting, tasks: window.tasks,
                                     reveal: { hooks.reveal(terminal: $0) }) { [weak self] in self?.bringToFront() }
        statusItem = status
        status.start()
        hotkey = GlobalHotkey { [weak self] in self?.toggleFromHotkey() }
        // The Janelinha: off by default, switched from the menus.
        let monitor = MonitorPanelController(deck: window.deck) { hooks.reveal(terminal: $0) }
        self.monitor = monitor
        status.isMonitorEnabled = { [weak monitor] in monitor?.isEnabled ?? false }
        status.onToggleMonitor = { [weak self] in self?.toggleMonitor(nil) }
        if MonitorSettings.enabled { monitor.setEnabled(true, preview: false) }
        TaskManagerWindowController.shared = TaskManagerWindowController(
            deck: window.deck, mainWindow: window.window, reveal: { hooks.reveal(terminal: $0) }) { [weak window] in
            NSApp.activate(ignoringOtherApps: true)
            window?.window?.makeKeyAndOrderFront(nil)
        }
        #if DEBUG
        // For automated checks, which cannot click: open the task manager at launch
        // ("processes" also ticks Processos).
        let environment = ProcessInfo.processInfo.environment
        if let open = environment["DECKMUX_OPEN_TASK_MANAGER"] {
            TaskManagerWindowController.shared?.exposeForChecks()
            TaskManagerWindowController.shared?.show(includingProcesses: open == "processes")
        }
        #endif
        UNUserNotificationCenter.current().delegate = self
        window.present(restoring: SessionStore.loadForLaunch())
        startAutosave()
        NSApp.activate(ignoringOtherApps: true)
        if workspaces.root == nil { RootFolderPicker.choose(for: workspaces) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Brings the window to the front (menu bar, notifications, the hotkey).
    @MainActor private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = mainWindow?.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// The global shortcut: shows Deckmux, or hides it when it is already in front.
    @MainActor private func toggleFromHotkey() {
        if NSApp.isActive, let window = mainWindow?.window, window.isVisible, !window.isMiniaturized {
            Self.logger.info("Hotkey: hide")
            NSApp.hide(nil)
        } else {
            Self.logger.info("Hotkey: show")
            bringToFront()
        }
    }

    @MainActor @objc private func chooseHotkey(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? GlobalHotkey.Preset else { return }
        hotkey?.apply(preset)
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? GlobalHotkey.Preset) == preset ? .on : .off
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            claudeHooks?.clearFocusedAttention()
            monitor?.appDidBecomeActive()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        MainActor.assumeIsolated { monitor?.appDidResignActive() }
    }

    /// "Janelinha" in the menu bar menu and in Janela.
    @MainActor @objc private func toggleMonitor(_ sender: Any?) {
        guard let monitor else { return }
        monitor.setEnabled(!monitor.isEnabled)
    }

    /// The ✓ of "Janelinha" in the Janela menu follows the real state (the
    /// panel's own context menu can turn it off too).
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleMonitor(_:)) {
            item.state = MainActor.assumeIsolated { monitor?.isEnabled == true } ? .on : .off
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            autosaveTimer?.invalidate()
            // Claude sessions end as their terminals close; keep their IDs.
            claudeHooks?.isTerminating = true
            saveSession(includingScrollback: true)
            SessionStore.flushScrollback()
            claudeHooks?.stop()
        }
    }

    /// Tells libghostty whether the system is dark or light, so themes like
    /// "light:X,dark:Y" follow it, as Ghostty's own app does.
    private func observeAppearance() {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new, .initial]) { [weak self] app, _ in
            let isDark = app.effectiveAppearance.isDark
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let ghosttyApp = self.ghostty.app else { return }
                    let scheme = isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
                    GhosttyAppearance.scheme = scheme
                    ghostty_app_set_color_scheme(ghosttyApp, scheme)
                    for surface in self.mainWindow?.deck.allSurfaces ?? [] {
                        if let handle = surface.surface { ghostty_surface_set_color_scheme(handle, scheme) }
                    }
                }
            }
        }
        // The first value is needed before any terminal is created.
        if let ghosttyApp = ghostty.app {
            let scheme = NSApp.effectiveAppearance.isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
            GhosttyAppearance.scheme = scheme
            ghostty_app_set_color_scheme(ghosttyApp, scheme)
        }
    }

    // MARK: Session

    /// Saves the layout every few seconds (only when it changed) and, less
    /// often, the scrollback, so a crash loses little. Quitting saves both.
    @MainActor private func startAutosave() {
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.autosaveTicks += 1
                self.saveSession(includingScrollback: self.autosaveTicks % 4 == 0)
            }
        }
        autosaveTimer?.tolerance = 1
    }

    @MainActor private func saveSession(includingScrollback: Bool) {
        guard let deck = mainWindow?.deck else { return }
        if includingScrollback { deck.items.forEach { $0.layout.saveScrollback() } }
        let snapshot = deck.snapshot()
        SessionStore.save(snapshot)
        if includingScrollback { SessionStore.pruneScrollback(keeping: snapshot) }
    }

    @MainActor @objc private func newTerminal(_ sender: Any?) {
        mainWindow?.newItem()
    }

    @MainActor @objc private func reopenPreviousSession(_ sender: Any?) {
        guard let snapshot = SessionStore.loadPrevious(), mainWindow?.deck.restore(snapshot) == true else { NSSound.beep(); return }
    }

    @MainActor @objc private func toggleResumeClaude(_ sender: NSMenuItem) {
        SessionSettings.resumesClaudeSessions.toggle()
        sender.state = SessionSettings.resumesClaudeSessions ? .on : .off
    }

    @MainActor @objc private func showToday(_ sender: Any?) {
        mainWindow?.showToday()
    }

    @MainActor @objc private func showTaskManager(_ sender: Any?) {
        TaskManagerWindowController.shared?.show()
    }

    @MainActor @objc private func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "Seu centro de comando: terminais por workspace, a agenda do dia e as tarefas, num lugar só.\n\nTerminal: libghostty. Abas e splits: Bonsplit.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor @objc private func showPalette(_ sender: Any?) {
        mainWindow?.showPalette()
    }

    @MainActor @objc private func selectSidebarItem(_ sender: NSMenuItem) {
        mainWindow?.deck.selectItem(number: sender.tag)
    }

    @MainActor @objc private func chooseWorkspaceRoot(_ sender: Any?) {
        RootFolderPicker.choose(for: workspaces)
    }

    // Copy, paste and font size are Ghostty keybindings handled by the surface;
    // the menu only carries app-level commands.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let aboutItem = appMenu.addItem(withTitle: "Sobre o Deckmux", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(.separator())
        let rootItem = appMenu.addItem(withTitle: "Alterar pasta dos workspaces…", action: #selector(chooseWorkspaceRoot(_:)), keyEquivalent: "")
        rootItem.target = self
        let resumeItem = appMenu.addItem(withTitle: "Retomar conversas do Claude ao reabrir", action: #selector(toggleResumeClaude(_:)), keyEquivalent: "")
        resumeItem.target = self
        resumeItem.state = SessionSettings.resumesClaudeSessions ? .on : .off
        // The system-wide shortcut that shows Deckmux.
        let hotkeyItem = appMenu.addItem(withTitle: "Atalho para mostrar o Deckmux", action: nil, keyEquivalent: "")
        let hotkeyMenu = NSMenu()
        for preset in GlobalHotkey.Preset.allCases {
            if preset == .none { hotkeyMenu.addItem(.separator()) }
            let item = hotkeyMenu.addItem(withTitle: preset.title, action: #selector(chooseHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset
            item.state = GlobalHotkey.preset == preset ? .on : .off
        }
        hotkeyItem.submenu = hotkeyMenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ocultar Deckmux", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Encerrar Deckmux", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "Arquivo")
        let newItem = fileMenu.addItem(withTitle: "Novo terminal", action: #selector(newTerminal(_:)), keyEquivalent: "n")
        newItem.target = self
        let reopenItem = fileMenu.addItem(withTitle: "Reabrir sessão anterior", action: #selector(reopenPreviousSession(_:)), keyEquivalent: "O")
        reopenItem.target = self
        fileItem.submenu = fileMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Janela")
        let paletteItem = windowMenu.addItem(withTitle: "Paleta de comandos…", action: #selector(showPalette(_:)), keyEquivalent: "P")
        paletteItem.target = self
        let todayItem = windowMenu.addItem(withTitle: "Hoje", action: #selector(showToday(_:)), keyEquivalent: "0")
        todayItem.target = self
        let taskManagerItem = windowMenu.addItem(withTitle: "Gerenciador de tarefas…", action: #selector(showTaskManager(_:)), keyEquivalent: "")
        taskManagerItem.target = self
        let monitorItem = windowMenu.addItem(withTitle: "Janelinha", action: #selector(toggleMonitor(_:)), keyEquivalent: "")
        monitorItem.target = self
        // ⌘1…⌘9: the sidebar items, in order.
        for number in 1...9 {
            let item = windowMenu.addItem(withTitle: "Item \(number) da barra lateral", action: #selector(selectSidebarItem(_:)), keyEquivalent: "\(number)")
            item.target = self
            item.tag = number
        }
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        // ⌘W is Ghostty's close_surface; closing the window is ⌘⇧W, as in Ghostty.
        windowMenu.addItem(withTitle: "Fechar janela", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return main
    }

    func setSecureInput(_ mode: Ghostty.SetSecureInput) {
        let input = SecureInput.shared
        switch mode {
        case .on: input.global = true
        case .off: input.global = false
        case .toggle: input.global.toggle()
        }
    }
}

// Ghostty's runtime callbacks look surfaces up by ID.
extension AppDelegate: GhosttyAppDelegate, Ghostty.Delegate {
    // Ghostty calls this from user-notification callbacks, which may arrive off the main thread.
    nonisolated func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        let lookup = { @MainActor in
            self.mainWindow?.deck.allSurfaces.first { $0.id == uuid }
        }
        if Thread.isMainThread { return MainActor.assumeIsolated(lookup) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(lookup) }
    }

    func ghosttySurface(id: UUID) -> Ghostty.SurfaceView? {
        findSurface(forUUID: id)
    }
}

// Clicking a Claude notification shows its terminal; Ghostty's own
// notifications (OSC 9) go back to Ghostty.
extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let terminal = (response.notification.request.content.userInfo[ClaudeHookCenter.terminalKey] as? String).flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let terminal {
                    self.claudeHooks?.reveal(terminal: terminal)
                } else {
                    self.ghostty.handleUserNotification(response: response)
                }
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// Entry points the vendored Ghostty code calls on the app delegate.
extension AppDelegate {
    @objc func checkForUpdates(_ sender: Any?) {}

    @objc func closeAllWindows(_ sender: Any?) {
        NSApp.windows.forEach { $0.performClose(sender) }
    }

    @objc func toggleVisibility(_ sender: Any?) {
        if NSApp.isActive { NSApp.hide(sender) } else { NSApp.activate(ignoringOtherApps: true) }
    }

    @objc func toggleQuickTerminal(_ sender: Any?) {}

    func syncFloatOnTopMenu(_ window: NSWindow) {}

    func performGhosttyBindingMenuKeyEquivalent(with event: NSEvent) -> Bool {
        NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }
}
