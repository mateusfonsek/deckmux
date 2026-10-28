import AppKit
import Bonsplit
import Combine
import DeckmuxChat
import SwiftUI

/// One entry of the sidebar: a split layout of terminals with its own tabs.
/// Its workspace follows the folder of its focused terminal.
@MainActor
final class DeckItem: ObservableObject, Identifiable {
    let id: UUID
    let layout: TerminalLayout
    /// Bonsplit's panes with the portal on top. Stays in the window while the
    /// item is not selected (only hidden), so its terminals are never detached.
    let container: NSView

    @Published private(set) var directory: String?
    /// The focused terminal's raw title. Not published: Claude Code changes it
    /// about ten times a second while it works, and publishing redrew the
    /// whole sidebar and Hoje each time. What the UI shows (name, working,
    /// branch) is derived and published only when it actually changes.
    private(set) var title: String = ""
    /// Some terminal here has Claude Code waiting for the user.
    @Published private(set) var needsAttention = false
    /// The most urgent bell here (a question beats "finished") and its terminal.
    @Published private(set) var attention: (terminal: UUID, kind: AgentAttention)?
    /// Some terminal here is running Claude Code.
    @Published private(set) var runsClaude = false
    /// The sidebar label: the user's name for the item, else the automatic one.
    @Published private(set) var displayName = "~"
    /// The focused terminal's conversation while Claude Code runs there,
    /// otherwise its folder.
    private(set) var automaticName = "~" {
        didSet { updateDisplayName() }
    }
    /// The user's name and tag (sidebar menu → Personalizar…).
    @Published var customization: ChatCustomization? {
        didSet { updateDisplayName() }
    }
    /// The focused tab is a code tab: the sidebar shows its ‹/› icon.
    @Published private(set) var showsCode = false
    /// Claude Code is working (its title starts with a spinner, not ✳).
    @Published private(set) var claudeWorking = false
    /// The git branch of the focused terminal's folder, if it is in a repo.
    @Published private(set) var branch: String?

    private var focusObservation: AnyCancellable?
    private var branchFolder: String?
    private var branchCheckedAt = Date.distantPast
    private var attentionObservation: AnyCancellable?
    private var claudeObservation: AnyCancellable?

    init(ghostty: Ghostty.App, initialConfig: Ghostty.SurfaceConfiguration?, restoring saved: SessionSnapshot.Item? = nil) {
        id = saved?.id ?? UUID()
        layout = TerminalLayout(ghostty: ghostty, initialConfig: initialConfig, restoring: saved?.layout)
        let focusedSaved = saved?.layout.terminals.first { $0.id == saved?.focusedTerminal }
        let startDirectory = initialConfig?.workingDirectory
            ?? focusedSaved.flatMap { $0.kind == nil ? $0.directory : $0.code?.root }
            ?? saved?.layout.shells.first?.directory
            ?? saved?.layout.terminals.first?.code?.root
        directory = startDirectory
        customization = saved?.customization
        automaticName = TerminalLabel.folderName(startDirectory)

        let container = NSView()
        let panes = NSHostingView(rootView: TerminalLayoutView(layout: layout).environmentObject(ghostty))
        for view in [panes, layout.portal] as [NSView] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        container.wantsLayer = true
        self.container = container
        // Property observers do not run during init.
        updateDisplayName()
        layout.onPanesWillChange = { [weak container] in container?.crossfadeNextChange() }

        // The focused terminal, or the focused code tab's root while it has
        // focus: the item's folder, name and branch follow it.
        focusObservation = layout.$lastFocusedSurface
            .map { [weak self, layout] last -> AnyPublisher<FocusedTerminal?, Never> in
                guard let surface = last?.value ?? self?.layout.focusedSurface else {
                    return Just(nil).eraseToAnyPublisher()
                }
                return surface.$pwd.combineLatest(surface.$title, layout.$claudeSessions.map { $0[surface.id] != nil },
                                                  surface.$programStates.map { $0.values.contains(.working) }.removeDuplicates())
                    .map { FocusedTerminal(pwd: $0, title: $1, runsClaude: $2, reportsWorking: $3) }
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .combineLatest(layout.$focusedCodeRoot)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] terminal, codeRoot in
                guard let self else { return }
                if (codeRoot != nil) != self.showsCode { self.showsCode = codeRoot != nil }
                // With a code tab focused the folder, name and branch are its
                // root's; Claude in the last focused terminal (the split next
                // to it) still shows as working.
                if let terminal {
                    if terminal.title != self.title { self.title = terminal.title }
                    let working = terminal.runsClaude && (terminal.reportsWorking || TerminalLabel.isWorking(terminal.title))
                    if working != self.claudeWorking { self.claudeWorking = working }
                } else if codeRoot != nil, self.claudeWorking {
                    self.claudeWorking = false
                }
                if let codeRoot {
                    self.showFolder(codeRoot)
                    return
                }
                guard let terminal else { return }
                let (pwd, title, runsClaude) = (terminal.pwd, terminal.title, terminal.runsClaude)
                if let pwd, pwd != self.directory { self.directory = pwd }
                let name = TerminalLabel.plainName(pwd: pwd ?? self.directory, title: title, runsClaude: runsClaude)
                if name != self.automaticName { self.automaticName = name }
                self.updateBranch(in: pwd ?? self.directory)
            }
        claudeObservation = layout.$claudeSessions
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] value in self?.runsClaude = value }
        attentionObservation = layout.$attention
            .sink { [weak self] bells in
                guard let self else { return }
                let urgent = bells.first { if case .needsInput = $0.value { true } else { false } } ?? bells.first
                self.attention = urgent.map { (terminal: $0.key, kind: $0.value) }
                if self.needsAttention != !bells.isEmpty { self.needsAttention = !bells.isEmpty }
            }
    }

    func snapshot() -> SessionSnapshot.Item {
        .init(id: id, layout: layout.snapshot(), focusedTerminal: layout.focusedTabRecordID, customization: customization)
    }

    private func updateDisplayName() {
        let name = customization.displayName(automatic: automaticName)
        if name != displayName { displayName = name }
    }

    private struct FocusedTerminal {
        var pwd: String?
        var title: String
        var runsClaude: Bool
        var reportsWorking: Bool
    }

    /// A code tab has focus: the item's folder is its root.
    private func showFolder(_ root: String) {
        if root != directory { directory = root }
        let name = TerminalLabel.folderName(root)
        if name != automaticName { automaticName = name }
        updateBranch(in: root)
    }

    /// Titles change on every command, which also catches a checkout; the
    /// branch file is read at most every few seconds.
    private func updateBranch(in folder: String?) {
        guard folder != branchFolder || Date().timeIntervalSince(branchCheckedAt) > 5 else { return }
        branchFolder = folder
        branchCheckedAt = Date()
        let branch = GitBranch.current(in: folder)
        if branch != self.branch { self.branch = branch }
    }

}

/// The Bonsplit panes. Each tab only holds an anchor; its terminal is drawn
/// by the layout's portal on top of it.
private struct TerminalLayoutView: View {
    let layout: TerminalLayout

    var body: some View {
        BonsplitView(controller: layout.bonsplit) { tab, _ in
            TerminalPaneSlot(tab: tab.id, layout: layout)
        } emptyPane: { pane in
            Button("Novo terminal") { layout.addTab(config: nil, inPane: pane) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A tab's place in its pane. Reads the drop zone Bonsplit publishes for
/// portal-hosted content and hands it to the anchor, so the portal can draw
/// the preview over the terminal.
private struct TerminalPaneSlot: View {
    let tab: TabID
    let layout: TerminalLayout
    @Environment(\.paneDropZone) private var dropZone

    var body: some View {
        TerminalPortalAnchor(
            tab: tab,
            portal: layout.portal,
            dropZone: layout.dropPreview(dropZone, overPaneOf: tab)
        )
    }
}

extension NSView {
    /// Cross-fades from what is on screen now to the state after this runloop
    /// turn. Only the composited images blend: the terminals are not resized
    /// frame by frame, so the animation stays smooth.
    func crossfadeNextChange(duration: CFTimeInterval = 0.2) {
        guard let layer else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(transition, forKey: "deckmux.panes")
    }
}
