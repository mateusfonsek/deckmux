import AppKit
import Bonsplit
import Combine
import DeckmuxCode
import GhosttyKit
import SwiftUI

/// One split layout of terminals: Bonsplit owns the panes and tabs, and this
/// object owns the Ghostty surface behind each tab. Surfaces live here rather
/// than in SwiftUI so a re-rendered pane never takes a shell down with it, and
/// they are drawn by `portal`, above the panes, so they are never re-parented.
/// A tab can also be a code tab (`viewers`), drawn by the portal the same way.
final class TerminalLayout: ObservableObject, BonsplitDelegate {
    let bonsplit: BonsplitController
    let portal = TerminalPortalView()

    /// Shared by every layout, so a drag can be identified (which tab, from
    /// which pane) and told apart from a stale pasteboard after it ends.
    static let tabDrags = TabDragTransferRegistry()

    /// The tab drag in progress, if any.
    static var liveTabDrag: TabDragTransfer? {
        tabDrags.resolve(from: NSPasteboard(name: .drag))
    }

    /// The last terminal that had keyboard focus; drives unfocused-split dimming.
    @Published private(set) var lastFocusedSurface: Weak<Ghostty.SurfaceView>?
    @Published private(set) var isSplit = false
    private let ghostty: Ghostty.App
    private var surfaces: [TabID: Ghostty.SurfaceView] = [:]
    /// The code tabs, next to the terminals.
    private var viewers: [TabID: CodeViewer] = [:]
    /// Panes with an "Abrir código" still resolving its repository.
    var resolvingCodePanes: Set<PaneID?> = []
    /// The root of the code tab with keyboard focus; nil while a terminal has it.
    @Published private(set) var focusedCodeRoot: String?
    private var titleObservers: [TabID: AnyCancellable] = [:]
    private var tintObservers: [TabID: AnyCancellable] = [:]
    /// The Claude Code conversation each terminal runs, by terminal ID.
    @Published private(set) var claudeSessions: [UUID: ClaudeSession] = [:]
    /// Terminals whose Claude Code is waiting for the user, by terminal ID.
    @Published private(set) var attention: [UUID: AgentAttention] = [:]
    /// When each bell in `attention` rang (the menu bar says "há 2 min").
    private(set) var attentionSince: [UUID: Date] = [:]
    /// Set while a saved layout is rebuilt, so the placeholder tabs it closes
    /// do not move focus around.
    private var isRestoring = false
    private var configObserver: NSObjectProtocol?

    deinit {
        configObserver.map(NotificationCenter.default.removeObserver)
    }

    /// Called once the last tab is gone, so the window can close.
    var onEmpty: (() -> Void)?
    /// Called just before panes split or close, in the same runloop turn, so
    /// the host can animate the change.
    var onPanesWillChange: (() -> Void)?

    init(ghostty: Ghostty.App, initialConfig: Ghostty.SurfaceConfiguration? = nil, restoring saved: SessionSnapshot.Node? = nil) {
        self.ghostty = ghostty
        var configuration = BonsplitConfiguration(
            allowCloseLastPane: false,
            autoCloseEmptyPanes: true,
            contentViewLifecycle: .keepAllAlive,
            newTabPosition: .current
        )
        configuration.appearance.splitButtons = [.newTerminal, Self.newClaudeButton, Self.codeButton, .splitRight, .splitDown]
        // Bigger than Bonsplit's default (30 pt, 11 pt text): read all day.
        configuration.appearance.tabBarHeight = Theme.tabBarHeight
        configuration.appearance.tabTitleFontSize = Theme.tabTitleSize
        configuration.appearance.tabMinWidth = Theme.tabMinWidth
        configuration.appearance.tabMaxWidth = Theme.tabMaxWidth
        // Same as cmux: animating panes re-lays out the Metal surfaces every frame.
        configuration.appearance.enableAnimations = false
        configuration.appearance.animationDuration = 0
        bonsplit = BonsplitController(configuration: configuration, tabDragTransferRegistry: Self.tabDrags)
        bonsplit.delegate = self
        portal.onRefocus = { [weak self] tab in
            guard let self, let pane = self.bonsplit.paneId(containing: tab), pane == self.bonsplit.focusedPaneId,
                  self.bonsplit.selectedTabId(inPane: pane) == tab else { return }
            self.focus(tab: tab)
        }
        portal.isTabShown = { [weak self] tab in
            guard let self, let pane = self.bonsplit.paneId(containing: tab) else { return false }
            return self.bonsplit.selectedTabId(inPane: pane) == tab
        }
        portal.terminalBackground = NSColor(ghostty.config.backgroundColor)
            .withAlphaComponent(ghostty.config.backgroundOpacity)
        // The theme can change with the system appearance.
        configObserver = NotificationCenter.default.addObserver(forName: .ghosttyConfigDidChange, object: nil, queue: .main) { [weak self] note in
            guard note.object == nil, let self else { return }
            self.portal.terminalBackground = NSColor(self.ghostty.config.backgroundColor)
                .withAlphaComponent(self.ghostty.config.backgroundOpacity)
        }
        // Bonsplit seeds a "Welcome" tab; replace it with the first terminal,
        // or use it as a placeholder while a saved layout is rebuilt.
        let seeded = bonsplit.allTabIds
        if let saved, !saved.terminals.isEmpty {
            restore(saved, placeholders: seeded)
        } else {
            addTab(config: initialConfig, inPane: bonsplit.focusedPaneId)
            for tab in seeded { _ = bonsplit.closeTab(tab) }
        }
    }

    // MARK: Queries

    var allSurfaces: [Ghostty.SurfaceView] { Array(surfaces.values) }
    var hasMultipleTabs: Bool { bonsplit.focusedPaneId.map { bonsplit.tabIds(inPane: $0).count > 1 } ?? false }

    func surface(for tabId: TabID) -> Ghostty.SurfaceView? { surfaces[tabId] }

    func contains(_ surface: Ghostty.SurfaceView) -> Bool { tabId(of: surface) != nil }

    var focusedSurface: Ghostty.SurfaceView? {
        guard let pane = bonsplit.focusedPaneId,
              let tab = bonsplit.selectedTabId(inPane: pane) else { return nil }
        return surfaces[tab]
    }

    /// The code tab selected in the focused pane, if that tab is one.
    var focusedViewer: CodeViewer? {
        guard let pane = bonsplit.focusedPaneId,
              let tab = bonsplit.selectedTabId(inPane: pane) else { return nil }
        return viewers[tab]
    }

    var allViewers: [CodeViewer] { Array(viewers.values) }

    func viewer(for tab: TabID) -> CodeViewer? { viewers[tab] }

    /// The saved ID of the focused tab, terminal or code tab.
    var focusedTabRecordID: UUID? { focusedViewer?.id ?? focusedSurface?.id }

    private func tabId(of surface: Ghostty.SurfaceView) -> TabID? {
        surfaces.first { $0.value === surface }?.key
    }

    private func pane(of surface: Ghostty.SurfaceView) -> PaneID? {
        tabId(of: surface).flatMap { bonsplit.paneId(containing: $0) }
    }

    // MARK: Creating terminals

    @discardableResult
    func addTab(config: Ghostty.SurfaceConfiguration?, inPane pane: PaneID?, id: UUID? = nil, focus shouldFocus: Bool = true) -> TabID? {
        guard ghostty.app != nil else { return nil }
        // SwiftUI renders the new tab on a later pass, after the surface is registered.
        guard let tab = bonsplit.createTab(title: TerminalLabel.folderName(config?.workingDirectory), icon: Self.tabIcon, kind: "terminal", inPane: pane),
              let surface = makeSurface(config: config, id: id) else {
            return nil
        }
        register(surface, for: tab)
        bonsplit.updateTab(tab, tintHex: .some(Self.workspaceColor(config?.workingDirectory)))
        if shouldFocus { focus(surface) }
        return tab
    }

    /// Every terminal is created here, so each one gets Deckmux's environment
    /// with its own ID (inherited configs carry the parent terminal's).
    private func makeSurface(config: Ghostty.SurfaceConfiguration?, id: UUID?) -> Ghostty.SurfaceView? {
        guard let app = ghostty.app else { return nil }
        let id = id ?? UUID()
        var config = config ?? Ghostty.SurfaceConfiguration()
        config.environmentVariables.merge(AgentIntegration.environment(forTerminal: id)) { _, new in new }
        let surface = Ghostty.SurfaceView(app, baseConfig: config, uuid: id)
        if let handle = surface.surface { ghostty_surface_set_color_scheme(handle, GhosttyAppearance.scheme) }
        return surface
    }

    func split(from source: Ghostty.SurfaceView, direction: ghostty_action_split_direction_e, config: Ghostty.SurfaceConfiguration?) {
        guard let tab = tabId(of: source) else { return }
        split(from: tab, direction: direction, config: config)
    }

    /// Splits the pane holding `tab`, with a new terminal; from a code tab it
    /// opens in the tab's root.
    func split(from tab: TabID, direction: ghostty_action_split_direction_e, config: Ghostty.SurfaceConfiguration? = nil) {
        guard let sourcePane = bonsplit.paneId(containing: tab) else { return }
        let config = config ?? viewers[tab].map(Self.config(in:))
        let orientation: SplitOrientation
        let insertFirst: Bool
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_LEFT: (orientation, insertFirst) = (.horizontal, true)
        case GHOSTTY_SPLIT_DIRECTION_UP: (orientation, insertFirst) = (.vertical, true)
        case GHOSTTY_SPLIT_DIRECTION_DOWN: (orientation, insertFirst) = (.vertical, false)
        default: (orientation, insertFirst) = (.horizontal, false)
        }
        guard let surface = makeSurface(config: config, id: nil) else { return }
        let newTab = Bonsplit.Tab(title: TerminalLabel.folderName(config?.workingDirectory), icon: Self.tabIcon, kind: "terminal",
                                  tintHex: Self.workspaceColor(config?.workingDirectory))
        register(surface, for: newTab.id)
        guard bonsplit.splitPane(sourcePane, orientation: orientation, withTab: newTab, insertFirst: insertFirst) != nil else {
            unregister(newTab.id)
            return
        }
        focus(surface)
    }

    func newTab(nextTo source: Ghostty.SurfaceView?, config: Ghostty.SurfaceConfiguration?) {
        guard let tab = source.flatMap(tabId(of:)) else {
            addTab(config: config, inPane: bonsplit.focusedPaneId)
            return
        }
        newTerminalTab(nextTo: tab, config: config)
    }

    /// A new terminal tab in the pane holding `tab`; next to a code tab it
    /// opens in the tab's root.
    func newTerminalTab(nextTo tab: TabID, config: Ghostty.SurfaceConfiguration? = nil) {
        let config = config ?? viewers[tab].map(Self.config(in:))
        addTab(config: config, inPane: bonsplit.paneId(containing: tab) ?? bonsplit.focusedPaneId)
    }

    /// Configuration for a terminal opened from Bonsplit's own buttons: inherit
    /// the focused terminal's directory, as Ghostty's keybindings do, or the
    /// focused code tab's root.
    private func inheritedConfig(context: ghostty_surface_context_e) -> Ghostty.SurfaceConfiguration? {
        if let viewer = focusedViewer { return Self.config(in: viewer) }
        guard let surface = focusedSurface?.surface else { return nil }
        return Ghostty.SurfaceConfiguration(from: ghostty_surface_inherited_config(surface, context))
    }

    // MARK: Session

    /// This layout as saved in the session: the split tree with each pane's
    /// tabs in order.
    func snapshot() -> SessionSnapshot.Node {
        snapshot(of: bonsplit.treeSnapshot())
    }

    private func snapshot(of node: ExternalTreeNode) -> SessionSnapshot.Node {
        switch node {
        case .pane(let pane):
            // Terminals and code tabs, in the pane's order.
            let selectedTab = pane.selectedTabId.flatMap(UUID.init(uuidString:))
            var tabs: [SessionSnapshot.Terminal] = []
            var selected: UUID?
            for saved in pane.tabs {
                guard let uuid = UUID(uuidString: saved.id) else { continue }
                let tab = TabID(uuid: uuid)
                let record: SessionSnapshot.Terminal
                if let surface = surfaces[tab] {
                    record = .init(id: surface.id, directory: surface.pwd, claude: claudeSessions[surface.id])
                } else if let viewer = viewers[tab] {
                    record = .init(id: viewer.id, directory: viewer.root.path, claude: nil, kind: Self.codeTabKind, code: viewer.state)
                } else {
                    continue
                }
                tabs.append(record)
                if uuid == selectedTab { selected = record.id }
            }
            return .pane(.init(terminals: tabs, selectedTerminal: selected))
        case .split(let split):
            return .split(.init(
                orientation: split.orientation == "vertical" ? .vertical : .horizontal,
                dividerPosition: split.dividerPosition,
                first: snapshot(of: split.first),
                second: snapshot(of: split.second)
            ))
        }
    }

    /// Saves the scrollback of every terminal for the next launch.
    func saveScrollback() {
        for surface in surfaces.values {
            guard let handle = surface.surface else { continue }
            SessionStore.saveScrollback(of: handle, terminal: surface.id)
        }
    }

    /// Rebuilds a saved layout, as cmux does: first the split tree with a
    /// placeholder tab in each new pane, then the terminals of each pane, then
    /// the placeholders go away.
    private func restore(_ saved: SessionSnapshot.Node, placeholders seeded: [TabID]) {
        guard let root = bonsplit.allPaneIds.first else { return }
        isRestoring = true
        defer { isRestoring = false }
        var placeholders = seeded
        var leaves: [(PaneID, SessionSnapshot.Pane)] = []
        scaffold(saved, in: root, leaves: &leaves, placeholders: &placeholders)

        let resumesClaude = SessionSettings.resumesClaudeSessions
        for (pane, savedPane) in leaves {
            var selected: TabID?
            for terminal in savedPane.terminals {
                let opened: TabID?
                switch terminal.kind {
                case Self.codeTabKind?:
                    // Code tabs come back as code tabs, never as shells.
                    guard let root = terminal.code?.root ?? terminal.directory else { continue }
                    opened = openCode(root: URL(fileURLWithPath: root, isDirectory: true), inPane: pane,
                                      state: terminal.code, id: terminal.id, focus: false)
                case nil:
                    let claude = resumesClaude && terminal.claude?.hasTranscript != false ? terminal.claude : nil
                    opened = addTab(config: restoredConfig(terminal, claude: claude), inPane: pane, id: terminal.id, focus: false)
                    if opened != nil, let claude { claudeSessions[terminal.id] = claude }
                default:
                    // A kind this version does not know.
                    continue
                }
                guard let tab = opened else { continue }
                // New tabs go after the selected one; keep the saved order.
                bonsplit.selectTab(tab)
                if terminal.id == savedPane.selectedTerminal { selected = tab }
            }
            if let selected { bonsplit.selectTab(selected) }
        }
        for tab in placeholders { _ = bonsplit.closeTab(tab) }
        if surfaces.isEmpty && viewers.isEmpty { addTab(config: nil, inPane: bonsplit.allPaneIds.first, focus: false) }
    }

    private func scaffold(
        _ node: SessionSnapshot.Node,
        in pane: PaneID,
        leaves: inout [(PaneID, SessionSnapshot.Pane)],
        placeholders: inout [TabID]
    ) {
        switch node {
        case .pane(let saved):
            leaves.append((pane, saved))
        case .split(let split):
            let placeholder = Bonsplit.Tab(title: "", kind: "restoring")
            guard let second = bonsplit.splitPane(
                pane,
                orientation: split.orientation == .vertical ? .vertical : .horizontal,
                withTab: placeholder,
                insertFirst: false,
                initialDividerPosition: CGFloat(split.dividerPosition)
            ) else {
                // Keep the terminals even if the split cannot be rebuilt.
                leaves.append((pane, .init(terminals: node.terminals, selectedTerminal: nil)))
                return
            }
            placeholders.append(placeholder.id)
            scaffold(split.first, in: pane, leaves: &leaves, placeholders: &placeholders)
            scaffold(split.second, in: second, leaves: &leaves, placeholders: &placeholders)
        }
    }

    /// A restored terminal opens in its folder, prints its saved scrollback
    /// and, when it was running Claude Code, reopens the same conversation.
    private func restoredConfig(_ terminal: SessionSnapshot.Terminal, claude: ClaudeSession?) -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        let directory = claude?.directory ?? terminal.directory
        if let directory, FileManager.default.fileExists(atPath: directory) {
            config.workingDirectory = directory
        }
        if let replay = SessionStore.scrollbackReplayFile(for: terminal.id) {
            config.environmentVariables["DECKMUX_RESTORE_SCROLLBACK_FILE"] = replay
        }
        if let claude {
            config.initialInput = "claude --resume \(AgentIntegration.shellQuoted(claude.sessionID))\n"
        }
        return config
    }

    /// Makes the terminal saved as focused the active pane and tab; keyboard
    /// focus follows when the item is shown.
    func restoreFocus(_ id: UUID?) {
        guard let id else { return }
        if let surface = terminal(withID: id) {
            syncBonsplitSelection(to: surface)
        } else if let (tab, viewer) = viewers.first(where: { $0.value.id == id }) {
            syncBonsplitSelection(to: tab)
            // The item shows its code tab (folder, ‹/› icon) before it is first focused.
            focusedCodeRoot = viewer.root.path
        }
    }

    // MARK: Claude Code

    func terminal(withID id: UUID) -> Ghostty.SurfaceView? {
        surfaces.values.first { $0.id == id }
    }

    func setClaudeSession(_ session: ClaudeSession?, forTerminal id: UUID) {
        claudeSessions[id] = session
    }

    /// Marks or clears the bell on a terminal's tab.
    func setAttention(_ value: AgentAttention?, forTerminal id: UUID) {
        guard attention[id] != value, let surface = terminal(withID: id), let tab = tabId(of: surface) else { return }
        attention[id] = value
        attentionSince[id] = value == nil ? nil : Date()
        bonsplit.updateTab(tab, showsNotificationBadge: value != nil)
        portal.setAttention(value != nil, for: tab)
    }

    // MARK: Closing terminals

    /// Closes the tab holding `surface`, asking first when a process is still running.
    func close(_ surface: Ghostty.SurfaceView, confirm: Bool) {
        guard let tab = tabId(of: surface) else { return }
        closeTab(tab, confirm: confirm)
    }

    /// Closes `tab`; with `confirm`, asks first. Code tabs close without asking.
    func closeTab(_ tab: TabID, confirm: Bool = false) {
        if confirm, surfaces[tab] != nil, !confirmClose() { return }
        skipCloseConfirmation = true
        defer { skipCloseConfirmation = false }
        _ = bonsplit.closeTab(tab)
    }

    private var skipCloseConfirmation = false

    private func confirmClose() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Fechar este terminal?"
        alert.informativeText = "Ainda há um processo rodando nele."
        alert.addButton(withTitle: "Fechar")
        alert.addButton(withTitle: "Cancelar")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Tab drag preview

    /// The zone to preview while a tab is dragged over the pane holding `tab`,
    /// or nil when dropping there would change nothing.
    func dropPreview(_ zone: DropZone?, overPaneOf tab: TabID) -> DropZone? {
        guard let zone, let pane = bonsplit.paneId(containing: tab) else { return nil }
        guard let drag = Self.liveTabDrag else { return zone }
        // Tabs from another sidebar item cannot be dropped here.
        guard bonsplit.paneId(containing: drag.tab.id) != nil else { return nil }
        // A pane's only tab dropped on that pane's own edge is vetoed in
        // shouldSplitPane; dropping it back on the center changes nothing but,
        // as in cmux, still shows where it would land.
        if drag.sourcePaneId == pane, zone != .center, bonsplit.tabIds(inPane: pane).count <= 1 { return nil }
        return zone
    }

    // MARK: Closing everything

    /// Every terminal here that is running something other than an idle shell.
    var busySurfaces: [Ghostty.SurfaceView] { surfaces.values.filter(\.needsConfirmQuit) }

    /// Tears down every terminal at once (closing a sidebar item). Hosting views
    /// keep the layout alive through their SwiftUI content, so each one is
    /// removed explicitly for the surfaces and their shells to be freed.
    func closeAll() {
        for tab in Array(surfaces.keys) + Array(viewers.keys) { unregister(tab) }
    }

    // MARK: Focus

    /// Gives `surface` keyboard focus and makes Bonsplit show it as the active
    /// tab and pane. Bonsplit's resulting delegate callbacks are ignored, so
    /// focus moves once per action instead of bouncing between surfaces.
    func focus(_ surface: Ghostty.SurfaceView) {
        syncBonsplitSelection(to: surface)
        if !isFirstResponder(surface) { Ghostty.moveFocus(to: surface) }
    }

    /// Focuses `tab`, a terminal or a code tab.
    func focus(tab: TabID) {
        if let surface = surfaces[tab] {
            focus(surface)
        } else if viewers[tab] != nil {
            syncBonsplitSelection(to: tab)
            focusCodeHost(of: tab)
        }
    }

    /// Gives keyboard focus to the tab selected in the focused pane.
    func focusSelectedTab() {
        guard let pane = bonsplit.focusedPaneId, let tab = bonsplit.selectedTabId(inPane: pane) else { return }
        focus(tab: tab)
    }

    /// Called when a code tab (or a view inside it) becomes the first responder.
    func codeDidBecomeFocused(_ tab: TabID) {
        guard let viewer = viewers[tab] else { return }
        syncBonsplitSelection(to: tab)
        if focusedCodeRoot != viewer.root.path { focusedCodeRoot = viewer.root.path }
    }

    /// Mirrors a focus change that already happened in AppKit (a click into a
    /// terminal) onto Bonsplit's pane and tab selection.
    func syncBonsplitSelection(to surface: Ghostty.SurfaceView) {
        guard let tab = tabId(of: surface) else { return }
        syncBonsplitSelection(to: tab)
    }

    func syncBonsplitSelection(to tab: TabID) {
        guard let pane = bonsplit.paneId(containing: tab) else { return }
        drivingSelection = true
        defer { drivingSelection = false }
        if bonsplit.focusedPaneId != pane { bonsplit.focusPane(pane) }
        if bonsplit.selectedTabId(inPane: pane) != tab { bonsplit.selectTab(tab) }
        portal.reposition()
    }

    private var drivingSelection = false

    private func isFirstResponder(_ surface: Ghostty.SurfaceView) -> Bool {
        surface.window?.firstResponder === surface
    }

    func canMoveFocus(_ direction: Ghostty.SplitFocusDirection, from surface: Ghostty.SurfaceView) -> Bool {
        guard let pane = pane(of: surface) else { return false }
        switch direction {
        case .previous, .next: return isSplit
        default: return navigationDirection(direction).flatMap { bonsplit.adjacentPane(to: pane, direction: $0) } != nil
        }
    }

    func moveFocus(_ direction: Ghostty.SplitFocusDirection, from surface: Ghostty.SurfaceView) {
        guard let tab = tabId(of: surface) else { return }
        moveFocus(direction, fromTab: tab)
    }

    func moveFocus(_ direction: Ghostty.SplitFocusDirection, fromTab tab: TabID) {
        guard let pane = bonsplit.paneId(containing: tab) else { return }
        let target: PaneID?
        switch direction {
        case .previous, .next:
            let panes = bonsplit.allPaneIds
            guard let index = panes.firstIndex(of: pane), panes.count > 1 else { return }
            let step = direction == .next ? 1 : -1
            target = panes[(index + step + panes.count) % panes.count]
        default:
            target = navigationDirection(direction).flatMap { bonsplit.adjacentPane(to: pane, direction: $0) }
        }
        guard let target, let next = bonsplit.selectedTabId(inPane: target) else { return }
        focus(tab: next)
    }

    func gotoTab(_ index: ghostty_action_goto_tab_e, from surface: Ghostty.SurfaceView) {
        guard let tab = tabId(of: surface) else { return }
        gotoTab(index, fromTab: tab)
    }

    func gotoTab(_ index: ghostty_action_goto_tab_e, fromTab current: TabID) {
        guard let pane = bonsplit.paneId(containing: current) else { return }
        let tabs = bonsplit.tabIds(inPane: pane)
        guard !tabs.isEmpty, let position = tabs.firstIndex(of: current) else { return }
        let target: Int
        switch index {
        case GHOSTTY_GOTO_TAB_PREVIOUS: target = (position - 1 + tabs.count) % tabs.count
        case GHOSTTY_GOTO_TAB_NEXT: target = (position + 1) % tabs.count
        case GHOSTTY_GOTO_TAB_LAST: target = tabs.count - 1
        // goto_tab:N counts from 1.
        default: target = max(0, min(Int(index.rawValue) - 1, tabs.count - 1))
        }
        focus(tab: tabs[target])
    }

    func moveTab(of surface: Ghostty.SurfaceView, by amount: Int) {
        guard let tab = tabId(of: surface), let pane = pane(of: surface) else { return }
        let tabs = bonsplit.tabIds(inPane: pane)
        guard let position = tabs.firstIndex(of: tab) else { return }
        _ = bonsplit.reorderTab(tab, toIndex: max(0, min(tabs.count - 1, position + amount)))
    }

    func toggleZoom(of surface: Ghostty.SurfaceView) {
        guard let tab = tabId(of: surface) else { return }
        toggleZoom(ofTab: tab)
    }

    func toggleZoom(ofTab tab: TabID) {
        guard let pane = bonsplit.paneId(containing: tab) else { return }
        _ = bonsplit.togglePaneZoom(inPane: pane)
    }

    private func navigationDirection(_ direction: Ghostty.SplitFocusDirection) -> NavigationDirection? {
        switch direction {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        case .previous, .next: nil
        }
    }

    // MARK: Bookkeeping

    private func register(_ surface: Ghostty.SurfaceView, for tab: TabID) {
        surfaces[tab] = surface
        observeTitle(of: surface, tab: tab)
        portal.add(tab, surface: surface, content: PortalTerminal(surface: surface, layout: self).environmentObject(ghostty))
    }

    func register(_ viewer: CodeViewer, for tab: TabID) {
        viewers[tab] = viewer
        let host = portal.add(tab, code: viewer, content: CodeTabView(viewer: viewer))
        host?.onShortcut = { [weak self] shortcut in self?.perform(shortcut, inCodeTab: tab) }
        host?.onFocus = { [weak self] in self?.codeDidBecomeFocused(tab) }
        viewer.onClose = { [weak self] in self?.closeTab(tab) }
        viewer.onRequestFocus = { [weak self] in self?.focusCodeHost(of: tab) }
    }

    private func unregister(_ tab: TabID) {
        if let viewer = viewers.removeValue(forKey: tab) {
            // A closed tab watches nothing, even while something still holds it.
            viewer.isOnScreen = false
            if focusedCodeRoot == viewer.root.path, !viewers.values.contains(where: { $0.root == viewer.root }) {
                focusedCodeRoot = nil
            }
        }
        if let surface = surfaces.removeValue(forKey: tab) {
            claudeSessions.removeValue(forKey: surface.id)
            attention.removeValue(forKey: surface.id)
            attentionSince.removeValue(forKey: surface.id)
        }
        titleObservers.removeValue(forKey: tab)
        tintObservers.removeValue(forKey: tab)
        portal.remove(tab)
    }

    /// Bonsplit moves panes without telling their anchors when only an
    /// ancestor's origin changes; re-place every terminal after layout changes.
    private func layoutDidChange() {
        isSplit = bonsplit.allPaneIds.count > 1
        portal.needsLayout = true
        DispatchQueue.main.async { [weak self] in self?.portal.reposition() }
    }

    /// Called when a terminal becomes the window's first responder (a click, or focus moved by code).
    func surfaceDidBecomeFocused(_ surface: Ghostty.SurfaceView) {
        guard contains(surface) else { return }
        if focusedCodeRoot != nil { focusedCodeRoot = nil }
        if lastFocusedSurface?.value !== surface { lastFocusedSurface = .init(surface) }
        syncBonsplitSelection(to: surface)
        // Looking at the terminal is reading its bell.
        if NSApp.isActive { setAttention(nil, forTerminal: surface.id) }
    }

    /// Tabs are named after the terminal's folder, which the shell integration
    /// reports on every `cd` (Ghostty's title would show user@host first), or
    /// after the conversation while Claude Code runs there.
    private func observeTitle(of surface: Ghostty.SurfaceView, tab: TabID) {
        let id = surface.id
        titleObservers[tab] = surface.$pwd
            .combineLatest(surface.$title, $claudeSessions.map { $0[id] != nil }.removeDuplicates())
            .map { pwd, title, runsClaude in TerminalLabel.tabName(pwd: pwd, title: title, runsClaude: runsClaude) }
            .removeDuplicates()
            // Claude Code's spinner changes the title ~10 times a second; four
            // redraws of the tab bar a second keep it moving at a fraction of the cost.
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] name in self?.bonsplit.updateTab(tab, title: name) }
        // Each tab wears its terminal's workspace color.
        tintObservers[tab] = surface.$pwd
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pwd in self?.bonsplit.updateTab(tab, tintHex: .some(Self.workspaceColor(pwd))) }
    }

    static let tabIcon = "terminal.fill"
    /// Opens a terminal that starts Claude Code right away.
    static let newClaudeButton = BonsplitConfiguration.SplitActionButton(
        id: "newClaude", icon: .emoji("\u{2733}\u{FE0E}", scale: claudeMarkScale),
        tooltip: "Novo terminal com Claude", action: .custom("newClaude"))

    /// The sidebar's ✳ as text (U+FE0E keeps it from becoming the green
    /// emoji), so Bonsplit paints it with the same gray as the other buttons.
    /// Scaled from Bonsplit's 13 pt text so the glyph is as tall as its 12 pt symbols.
    private static let claudeMarkScale = 1.2
    /// The color (#RRGGBB) of the workspace holding a folder; set by the window.
    static var workspaceColor: (String?) -> String? = { _ in nil }

    /// Recolors every tab, after a workspace's color or folder changed.
    func refreshTints() {
        for (tab, surface) in surfaces {
            bonsplit.updateTab(tab, tintHex: .some(Self.workspaceColor(surface.pwd)))
        }
        for (tab, viewer) in viewers {
            let tint = Self.workspaceColor(viewer.root.path)
            bonsplit.updateTab(tab, tintHex: .some(tint))
            if viewer.tintHex != tint { viewer.tintHex = tint }
        }
    }

    func runsClaude(_ surface: Ghostty.SurfaceView) -> Bool { claudeSessions[surface.id] != nil }

    // MARK: BonsplitDelegate

    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        guard !skipCloseConfirmation, let surface = surfaces[tab.id], surface.needsConfirmQuit else { return true }
        return confirmClose()
    }

    func splitTabBar(_ controller: BonsplitController, didCloseTab tabId: TabID, fromPane pane: PaneID) {
        if surfaces.count + viewers.count > 1 { onPanesWillChange?() }
        unregister(tabId)
        layoutDidChange()
        if surfaces.isEmpty && viewers.isEmpty {
            onEmpty?()
        } else if !isRestoring, let next = focusedSurface {
            Ghostty.moveFocus(to: next)
        } else if !isRestoring, let pane = bonsplit.focusedPaneId, let next = bonsplit.selectedTabId(inPane: pane), viewers[next] != nil {
            focusCodeHost(of: next)
        }
    }

    func splitTabBar(_ controller: BonsplitController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation) {
        // Splits made from Bonsplit's buttons arrive empty; keyboard splits
        // already carry their tab.
        onPanesWillChange?()
        layoutDidChange()
        // Only Bonsplit's split buttons leave the new pane empty. Keyboard
        // splits and dragged tabs arrive with their tab already in it.
        guard controller.tabIds(inPane: newPane).isEmpty else { return }
        addTab(config: inheritedConfig(context: GHOSTTY_SURFACE_CONTEXT_SPLIT), inPane: newPane)
    }

    func splitTabBar(_ controller: BonsplitController, didRequestNewTab kind: String, inPane pane: PaneID) {
        addTab(config: inheritedConfig(context: GHOSTTY_SURFACE_CONTEXT_TAB), inPane: pane)
    }

    func splitTabBar(_ controller: BonsplitController, didRequestCustomAction identifier: String, inPane pane: PaneID) {
        switch identifier {
        case Self.newClaudeButton.id:
            var config = inheritedConfig(context: GHOSTTY_SURFACE_CONTEXT_TAB) ?? Ghostty.SurfaceConfiguration()
            config.initialInput = "claude\n"
            addTab(config: config, inPane: pane)
        case Self.codeButton.id:
            openCodeForFocusedFolder(inPane: pane)
        default:
            break
        }
    }

    func splitTabBar(_ controller: BonsplitController, didSelectTab tab: Bonsplit.Tab, inPane pane: PaneID) {
        portal.reposition()
        // A restored layout selects every tab it adds; focus goes to the shown
        // item's selected tab once the item is on screen.
        guard !drivingSelection, !isRestoring else { return }
        if viewers[tab.id] != nil {
            focusCodeHost(of: tab.id)
            return
        }
        guard let surface = surfaces[tab.id], !isFirstResponder(surface) else { return }
        Ghostty.moveFocus(to: surface)
    }

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
        guard !drivingSelection, !isRestoring, let tab = controller.selectedTabId(inPane: pane) else { return }
        if viewers[tab] != nil {
            focusCodeHost(of: tab)
            return
        }
        guard let surface = surfaces[tab], !isFirstResponder(surface) else { return }
        Ghostty.moveFocus(to: surface)
    }

    /// Dragging a pane's only tab to that pane's own edge would split it into the
    /// tab and an empty placeholder. Treat it as dropping the tab back.
    func splitTabBar(_ controller: BonsplitController, shouldSplitPane pane: PaneID, orientation: SplitOrientation) -> Bool {
        guard let drag = Self.liveTabDrag, drag.sourcePaneId == pane else { return true }
        return controller.tabIds(inPane: pane).count > 1
    }

    func splitTabBar(_ controller: BonsplitController, didMoveTab tab: Bonsplit.Tab, fromPane source: PaneID, toPane destination: PaneID) {
        onPanesWillChange?()
        layoutDidChange()
        focus(tab: tab.id)
    }

    func splitTabBar(_ controller: BonsplitController, didClosePane paneId: PaneID) {
        layoutDidChange()
    }

    func splitTabBar(_ controller: BonsplitController, didChangeGeometry snapshot: LayoutSnapshot) {
        layoutDidChange()
    }

    func splitTabBar(_ controller: BonsplitController, shouldNotifyDuringDrag: Bool) -> Bool { true }
}

/// A terminal as drawn in the portal: Ghostty's own surface view, with the
/// focus state it needs to dim unfocused splits. While a code tab has the
/// keys no terminal counts as focused, so every split dims.
private struct PortalTerminal: View {
    let surface: Ghostty.SurfaceView
    @ObservedObject var layout: TerminalLayout

    var body: some View {
        Ghostty.InspectableSurface(surfaceView: surface, isSplit: layout.isSplit)
            .ghosttyLastFocusedSurface(layout.focusedCodeRoot == nil ? layout.lastFocusedSurface : nil)
    }
}
