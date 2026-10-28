import AppKit
import Combine
import DeckmuxMonitor
import SwiftUI

/// The Janelinha's window: a non-activating floating panel in the
/// bottom-right corner, shown only while Deckmux is not the active app (plus a
/// 4 s preview when turned on), collapsible, draggable, remembered.
@MainActor
final class MonitorPanelController: NSObject, NSWindowDelegate {
    let model: MonitorModel
    private let watcher = SubagentWatcher()
    private let usage = UsageClient()
    private let reveal: (UUID) -> Void
    private let panel: NSPanel
    private let background: MonitorBackgroundView
    private let scroll = NSScrollView()
    private let hosting: NSHostingView<MonitorView>
    private var observers: [AnyCancellable] = []
    private var appearanceObserver: NSKeyValueObservation?

    private(set) var isEnabled = false
    private var appActive = NSApp.isActive
    private var previewTimer: Timer?
    private var previewing = false
    private var layingOut = false

    init(deck: Deck, reveal: @escaping (UUID) -> Void) {
        model = MonitorModel(deck: deck)
        self.reveal = reveal
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: MonitorView.width, height: 100),
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        background = MonitorBackgroundView()
        hosting = NSHostingView(rootView: MonitorView(model: model, collapsed: false, onReveal: { _ in }, onToggleCollapse: {}))
        super.init()

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setAccessibilityLabel("Janelinha")

        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Theme.Radius.panel
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.onContextMenu = { [weak self] event in self?.showContextMenu(event) }

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = hosting
        scroll.autoresizingMask = [.width, .height]
        background.addSubview(scroll)
        panel.contentView = background

        hosting.rootView = MonitorView(model: model, collapsed: false,
                                       onReveal: { [weak self] id in self?.reveal(id) },
                                       onToggleCollapse: { [weak self] in self?.toggleCollapsed() })

        watcher.onChange = { [weak self] id, agents in self?.model.setSubagents(agents, forTerminal: id) }
        usage.onUpdate = { [weak self] usage, failure in self?.usageUpdated(usage, failure) }
        observers.append(model.$sessions.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] sessions in
            self?.sessionsChanged(sessions)
        })
        observers.append(model.$usage.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.relayoutIfVisible() })
        observers.append(model.$usageProblem.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.relayoutIfVisible() })
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] app, _ in
            let dark = app.effectiveAppearance.isDark
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.background.material = dark ? .hudWindow : .popover } }
        }
    }

    // MARK: On / off

    /// Turns the Janelinha on (with a 4 s preview even if Deckmux is in front) or off.
    func setEnabled(_ enabled: Bool, preview: Bool = true) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        model.setEnabled(enabled)
        if enabled {
            usage.start()
            if preview {
                previewing = true
                previewTimer?.invalidate()
                previewTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.previewing = false
                        self?.updateVisibility()
                    }
                }
            }
            relayout()
        } else {
            usage.stop()
            watcher.stop()
            previewTimer?.invalidate()
            previewing = false
        }
        updateVisibility()
    }

    func appDidBecomeActive() {
        appActive = true
        updateVisibility()
    }

    func appDidResignActive() {
        appActive = false
        updateVisibility()
    }

    private var shouldShow: Bool { isEnabled && (!appActive || previewing) }

    private func updateVisibility() {
        if shouldShow {
            if !panel.isVisible {
                relayout()
                panel.orderFrontRegardless()
            }
            model.setVisible(true)
        } else if panel.isVisible {
            panel.orderOut(nil)
            model.setVisible(false)
        } else {
            model.setVisible(false)
        }
    }

    // MARK: Collapsing

    /// Collapsed stays collapsed, mouse over it or not, until the user clicks
    /// it; the chevron in the full form collapses it again.
    var isCollapsed: Bool { MonitorSettings.collapsed }

    func toggleCollapsed() {
        MonitorSettings.collapsed.toggle()
        relayout()
    }

    private var effectiveCollapsed: Bool { MonitorSettings.collapsed }

    private func showContextMenu(_ event: NSEvent) {
        let menu = NSMenu()
        let collapse = NSMenuItem(title: MonitorSettings.collapsed ? "Expandir" : "Recolher", action: #selector(toggleCollapsedAction(_:)), keyEquivalent: "")
        collapse.target = self
        menu.addItem(collapse)
        menu.addItem(.separator())
        let off = NSMenuItem(title: "Desligar janelinha", action: #selector(turnOff(_:)), keyEquivalent: "")
        off.target = self
        menu.addItem(off)
        NSMenu.popUpContextMenu(menu, with: event, for: background)
    }

    @objc private func toggleCollapsedAction(_ sender: Any?) { toggleCollapsed() }
    @objc private func turnOff(_ sender: Any?) { setEnabled(false) }

    // MARK: Data

    private func sessionsChanged(_ sessions: [MonitorSession]) {
        let watched = sessions.compactMap { session -> (terminal: UUID, cwd: String, sessionID: String)? in
            guard let cwd = session.cwd else { return nil }
            return (session.id, cwd, session.sessionID)
        }
        if isEnabled { watcher.watch(watched) }
        relayoutIfVisible()
    }

    /// Hidden (Deckmux in front), the panel is not laid out on every sample;
    /// `updateVisibility` lays it out right before showing it.
    private func relayoutIfVisible() {
        if panel.isVisible { relayout() }
    }

    private func usageUpdated(_ usage: Usage?, _ failure: UsageClient.Failure?) {
        let problem: String?
        switch failure {
        case nil: problem = nil
        case .noToken?, .unauthorized?: problem = "Uso: faça /login no Claude Code"
        case .keychainDenied?: problem = "Uso: acesso ao Keychain negado"
        case .malformed?: problem = "Uso indisponível"
        case .network?, .rateLimited?:
            if let usage { problem = "⚠ \(AgentStatusItem.ago(usage.fetchedAt, now: Date()))" } else { problem = "Uso indisponível" }
        }
        model.setUsage(usage, problem: problem)
    }

    // MARK: Layout

    /// Fits the panel to its content (up to 60 % of the screen, scrolling
    /// beyond) and keeps its bottom-right corner where it was.
    private func relayout() {
        guard isEnabled else { return }
        let collapsed = effectiveCollapsed
        hosting.rootView = MonitorView(model: model, collapsed: collapsed,
                                       onReveal: { [weak self] id in self?.reveal(id) },
                                       onToggleCollapse: { [weak self] in self?.toggleCollapsed() })
        let width = collapsed ? MonitorView.collapsedWidth : MonitorView.width
        let fit = hosting.fittingSize
        let screens = Self.screens
        let index = PanelPlacement.screenIndex(savedCorner: MonitorSettings.origin, screens: screens)
        let maxHeight = (screens.indices.contains(index) ? screens[index].visible.height : 800) * 0.6
        let height = min(max(fit.height, 20), maxHeight)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: fit.height)
        let frame = PanelPlacement.frame(size: CGSize(width: width, height: height), savedCorner: MonitorSettings.origin, screens: screens)
        layingOut = true
        panel.setFrame(frame, display: true)
        scroll.frame = background.bounds
        layingOut = false
        // Content grows upward: keep the latest rows in view from the top.
        scroll.documentView?.scroll(NSPoint(x: 0, y: 0))
    }

    /// The screens for `PanelPlacement`, the main one first.
    private static var screens: [PanelPlacement.Screen] {
        let main = NSScreen.main
        let ordered = ([main].compactMap { $0 } + NSScreen.screens.filter { $0 != main })
        return ordered.map { ($0.frame, $0.visibleFrame) }
    }

    func windowDidMove(_ notification: Notification) {
        guard !layingOut else { return }
        MonitorSettings.origin = CGPoint(x: panel.frame.maxX, y: panel.frame.minY)
    }
}

/// The material behind the content; the right-click menu lands here.
final class MonitorBackgroundView: NSVisualEffectView {
    var onContextMenu: ((NSEvent) -> Void)?

    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }
}
