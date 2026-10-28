import AppKit
import Bonsplit
import Combine
import GhosttyKit
import SwiftUI

/// The Deckmux window: the sidebar of items on the left and the selected
/// item's tabs and splits on the right. It answers Ghostty's keybinding
/// notifications for every terminal in the window.
final class MainWindowController: NSWindowController, NSWindowDelegate, GhosttyTerminalHost {
    static let sidebarWidth = Theme.sidebarWidth

    let deck: Deck
    private let content = NSView()
    private var observers: [NSObjectProtocol] = []
    private var firstResponderObservation: NSKeyValueObservation?
    /// The code tab that last had the focus, while it still has it.
    private weak var lastCodeHost: CodeTabHostView?
    /// Shown behind the items; visible only when there are none.
    private var emptyView: NSView?
    let workspacesModel: WorkspacesModel
    let nextMeeting: NextMeetingModel
    let tasks = TasksModel()
    /// Hoje and the Workspaces tab, over the terminals while open.
    private var pageViews: [Deck.Page: NSView] = [:]
    private var shownPage: NSView?

    init(ghostty: Ghostty.App, workspaces: WorkspaceStore) {
        deck = Deck(ghostty: ghostty, workspaces: workspaces)
        // Tabs wear their workspace's color.
        TerminalLayout.workspaceColor = { [weak workspaces] path in
            MainActor.assumeIsolated { workspaces?.workspace(containing: path)?.manifest.color }
        }
        workspacesModel = WorkspacesModel(store: workspaces)
        nextMeeting = NextMeetingModel(store: workspaces)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Deckmux"
        // No titlebar of its own: the sidebar runs under the traffic
        // lights and the top bar takes the titlebar's place, as in cmux and Arc.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let toolbar = NSToolbar(identifier: "DeckmuxMain")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.minSize = NSSize(width: 820, height: 520)
        window.setFrameAutosaveName("DeckmuxMain")

        let root = NSView()
        let barHeight = Theme.topBarHeight
        // With a full-size content view the content spans the whole frame,
        // titlebar included.
        let size = window.frame.size
        root.frame = NSRect(origin: .zero, size: size)
        root.autoresizingMask = [.width, .height]
        let rest = size.width - Self.sidebarWidth
        content.frame = NSRect(x: Self.sidebarWidth, y: 0, width: rest, height: size.height - barHeight)
        content.autoresizingMask = [.width, .height]
        root.addSubview(content)
        let empty = NSHostingView(rootView: EmptyDeckView(deck: deck))
        empty.frame = content.bounds
        empty.autoresizingMask = [.width, .height]
        content.addSubview(empty)
        emptyView = empty
        pageViews[.workspaces] = PageHostingView(rootView: WorkspacesView(model: workspacesModel))
        pageViews[.today] = PageHostingView(rootView: TodayView(deck: deck, meetings: nextMeeting, tasks: tasks))
        for view in pageViews.values { view.autoresizingMask = [.width, .height] }
        window.contentView = root
        window.center()
        super.init(window: window)
        let sidebar = PageHostingView(rootView: SidebarView(deck: deck, meetings: nextMeeting) { [weak self] in self?.showPalette() })
        sidebar.frame = NSRect(x: 0, y: 0, width: Self.sidebarWidth, height: size.height)
        sidebar.autoresizingMask = [.height]
        root.addSubview(sidebar)
        let separator = NSBox()
        separator.boxType = .separator
        separator.frame = NSRect(x: Self.sidebarWidth - 1, y: 0, width: 1, height: size.height)
        separator.autoresizingMask = [.height]
        root.addSubview(separator)
        let topBar = PageHostingView(rootView: TopBarView(model: nextMeeting) { [weak self] in
            self?.deck.show(.today)
            self?.nextMeeting.guidePresented = true
        })
        topBar.frame = NSRect(x: Self.sidebarWidth, y: size.height - barHeight, width: rest, height: barHeight)
        topBar.autoresizingMask = [.width, .minYMargin]
        root.addSubview(topBar)
        window.delegate = self

        deck.onAdd = { [weak self] item in self?.mount(item) }
        deck.onRemove = { item in item.container.removeFromSuperview() }
        deck.onSelect = { [weak self] item in self?.show(item) }
        deck.onShowPage = { [weak self] page in self?.showPage(page) }
        workspacesModel.openTerminal = { [weak self] folder, input in
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = folder.path
            config.initialInput = input
            self?.deck.add(config: config)
        }
        workspaceObserver = workspaces.$workspaces.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.deck.items.forEach { $0.layout.refreshTints() } }
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTerminalsOnScreen() }
            })
        }
        // Terminals hidden for a minute give their GPU memory back (three
        // window-sized buffers, ~35 MB each at 2x); the renderer comes back
        // in a few ms when the terminal shows again.
        reclaimTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deck.items.forEach { $0.layout.portal.reclaimRenderers(hiddenLongerThan: Self.reclaimAfter) }
            }
        }
        reclaimTimer?.tolerance = 5
        observeGhosttyActions()
        firstResponderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let surface = window.firstResponder as? Ghostty.SurfaceView {
                    self.lastCodeHost = nil
                    self.deck.item(containing: surface)?.layout.surfaceDidBecomeFocused(surface)
                } else if let host = window.firstResponder?.enclosingCodeTabHost {
                    self.lastCodeHost = host
                    host.onFocus?()
                } else if window.firstResponder == nil || window.firstResponder === window {
                    if let host = self.lastCodeHost { self.refocus(host, in: window) }
                } else {
                    self.lastCodeHost = nil
                }
            }
        }
    }

    /// A view inside a code tab went away with the focus (the changes list,
    /// after switching to Arquivos) and AppKit handed it to the window, where
    /// ⌘W and ⌘D do nothing: back to the tab. Not when the tab itself was
    /// hidden (another tab, item or page), whoever hid it moves the focus.
    private func refocus(_ host: CodeTabHostView, in window: NSWindow) {
        DispatchQueue.main.async { [weak host, weak window] in
            guard let host, let window, host.window === window, !host.isHiddenOrHasHiddenAncestor,
                  window.firstResponder == nil || window.firstResponder === window else { return }
            window.makeFirstResponder(host)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Shows the window with the saved session, or with one terminal on the
    /// first launch. A session saved with no items opens empty.
    func present(restoring snapshot: SessionSnapshot? = nil) {
        if let snapshot {
            deck.restore(snapshot)
        } else {
            deck.add()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // The app opens on Hoje.
        deck.show(.today)
    }

    func showToday() { deck.show(.today) }

    // MARK: Command palette

    private var palette: PalettePanel?
    private var reclaimTimer: Timer?
    static var reclaimAfter: TimeInterval = ProcessInfo.processInfo.environment["DECKMUX_RECLAIM_AFTER"].flatMap(Double.init) ?? 60
    private var workspaceObserver: AnyCancellable?

    /// ⌘⇧P: opens the palette over the window, or closes it when open.
    func showPalette() {
        if let palette, palette.isVisible {
            palette.close()
            return
        }
        guard let window else { return }
        let entries = PaletteEntries.all(deck: deck, meetings: nextMeeting, tasks: tasks)
        let host = NSHostingView(rootView: CommandPaletteView(entries: entries) { [weak self] in self?.palette?.close() })
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let panel = PalettePanel(content: host)
        let frame = window.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - host.frame.width / 2,
                                     y: frame.maxY - max(80, frame.height * 0.16) - host.frame.height))
        panel.onClose = { [weak self, weak window] in
            self?.palette = nil
            window?.makeKeyAndOrderFront(nil)
        }
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        palette = panel
    }

    // MARK: Items

    /// Every item's view stays in the window; unselected ones are only hidden,
    /// so switching items never detaches a terminal.
    private func mount(_ item: DeckItem) {
        item.container.frame = content.bounds
        item.container.autoresizingMask = [.width, .height]
        item.container.isHidden = true
        item.layout.portal.isOnScreen = false
        content.addSubview(item.container)
    }

    /// A page sits on top of everything in the content area and is added only
    /// while open, so the terminals' layout is untouched.
    private func showPage(_ page: Deck.Page?) {
        shownPage?.removeFromSuperview()
        shownPage = nil
        guard let page, let view = pageViews[page] else {
            show(deck.selected)
            return
        }
        view.frame = content.bounds
        content.addSubview(view)
        shownPage = view
        // A hosting view does not take focus; the window does, so keys never
        // reach a hidden terminal. Done before hiding them: AppKit would hand
        // a hidden first responder's focus to some other terminal, and that
        // terminal's layout would change its selected tab.
        if window?.makeFirstResponder(view) != true { window?.makeFirstResponder(nil) }
        // Metal-backed terminals can draw over sibling views; hide them.
        for subview in content.subviews where subview !== view { subview.isHidden = true }
        updateTerminalsOnScreen()
    }

    /// Only the shown item's terminals draw; the others (another item, a page
    /// on top, a hidden or minimized window) are occluded.
    func updateTerminalsOnScreen() {
        let windowVisible = window?.occlusionState.contains(.visible) ?? false
        for item in deck.items {
            item.layout.portal.isOnScreen = windowVisible && shownPage == nil && item.id == deck.selectedID
        }
    }

    private func show(_ item: DeckItem?) {
        defer { updateTerminalsOnScreen() }
        guard shownPage == nil else { return }
        for view in content.subviews where view !== emptyView { view.isHidden = view !== item?.container }
        emptyView?.isHidden = item != nil
        item?.layout.portal.reposition()
        focusSelected()
    }

    /// "Novo terminal" (⌘N): a new item in the focused terminal's folder, as
    /// Ghostty's new window does.
    func newItem() {
        var config: Ghostty.SurfaceConfiguration?
        if let surface = deck.selected?.layout.focusedSurface?.surface {
            config = Ghostty.SurfaceConfiguration(from: ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_WINDOW))
        } else if let viewer = deck.selected?.layout.focusedViewer {
            config = Ghostty.SurfaceConfiguration()
            config?.workingDirectory = viewer.root.path
        }
        deck.add(config: config)
    }

    private func focusSelected() {
        deck.selected?.layout.focusSelectedTab()
    }

    // MARK: Ghostty actions

    private func observeGhosttyActions() {
        observe(Ghostty.Notification.ghosttyNewSplit) { layout, surface, info in
            guard let direction = info["direction"] as? ghostty_action_split_direction_e else { return }
            layout.split(from: surface, direction: direction, config: info[Ghostty.Notification.NewSurfaceConfigKey] as? Ghostty.SurfaceConfiguration)
        }
        observe(Ghostty.Notification.ghosttyNewTab) { layout, surface, info in
            layout.newTab(nextTo: surface, config: info[Ghostty.Notification.NewSurfaceConfigKey] as? Ghostty.SurfaceConfiguration)
        }
        observe(Ghostty.Notification.ghosttyCloseSurface) { layout, surface, info in
            layout.close(surface, confirm: info["process_alive"] as? Bool ?? false)
        }
        observe(Ghostty.Notification.ghosttyFocusSplit) { layout, surface, info in
            guard let direction = info[Ghostty.Notification.SplitDirectionKey] as? Ghostty.SplitFocusDirection else { return }
            layout.moveFocus(direction, from: surface)
        }
        observe(Ghostty.Notification.ghosttyGotoTab) { layout, surface, info in
            guard let tab = info[Ghostty.Notification.GotoTabKey] as? ghostty_action_goto_tab_e else { return }
            layout.gotoTab(tab, from: surface)
        }
        observe(.ghosttyMoveTab) { layout, surface, info in
            guard let move = info[Notification.Name.GhosttyMoveTabKey] as? Ghostty.Action.MoveTab else { return }
            layout.moveTab(of: surface, by: move.amount)
        }
        observe(Ghostty.Notification.didToggleSplitZoom) { layout, surface, _ in
            layout.toggleZoom(of: surface)
        }
        // Ghostty's "new window" (⌘N) opens a new sidebar item, as in cmux.
        let token = NotificationCenter.default.addObserver(
            forName: Ghostty.Notification.ghosttyNewWindow, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                _ = self?.deck.add(config: note.userInfo?[Ghostty.Notification.NewSurfaceConfigKey] as? Ghostty.SurfaceConfiguration)
            }
        }
        observers.append(token)
    }

    /// Runs `handler` for notifications whose object is a terminal in this window.
    private func observe(
        _ name: Notification.Name,
        handler: @escaping (TerminalLayout, Ghostty.SurfaceView, [AnyHashable: Any]) -> Void
    ) {
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            // queue: .main delivers on the main thread.
            MainActor.assumeIsolated {
                guard let self,
                      let surface = note.object as? Ghostty.SurfaceView,
                      let item = self.deck.item(containing: surface) else { return }
                handler(item.layout, surface, note.userInfo ?? [:])
            }
        }
        observers.append(token)
    }

    // MARK: GhosttyTerminalHost (answers for the item on screen)

    var isSplit: Bool { deck.selected?.layout.isSplit ?? false }
    var hasMultipleTabs: Bool { deck.selected?.layout.hasMultipleTabs ?? false }
    var focusedSurface: Ghostty.SurfaceView? { deck.selected?.layout.focusedSurface }
    var commandPaletteIsShowing: Bool { false }
    var focusFollowsMouse: Bool { false }
    var titleOverride: String?

    func canMoveFocus(_ direction: Ghostty.SplitFocusDirection, from surface: Ghostty.SurfaceView) -> Bool {
        deck.item(containing: surface)?.layout.canMoveFocus(direction, from: surface) ?? false
    }

    func toggleBackgroundOpacity() {}
    func promptTabTitle() {}
}

/// Hosts the sidebar, the top bar, Hoje and the Workspaces tab.
/// - An opaque hosting view may let AppKit read a press-and-drag (a task card)
///   as moving the window; Bonsplit's `NonDraggableHostingView` does the same.
/// - The content runs under the titlebar, so the titlebar's safe area would
///   push every SwiftUI view down by its height; the layout already leaves room.
private final class PageHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        safeAreaRegions = []
    }

    @MainActor @preconcurrency required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
