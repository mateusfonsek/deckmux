import AppKit
import Bonsplit
import GhosttyKit
import QuartzCore
import SwiftUI

/// Keeps every terminal (and code tab) of a window in one layer above the Bonsplit panes.
///
/// Bonsplit gives each pane its own hosting controller and rebuilds them when
/// panes split or close, so a terminal mounted inside a pane left the window
/// and came back on every layout change: one blank frame each time. Here each
/// terminal gets a hosting view created once and never re-parented; panes only
/// hold an empty `TerminalPortalAnchor`, and the portal moves the terminal over
/// whatever rect its anchor currently occupies. cmux solves the same problem
/// with its `TerminalWindowPortal`.
final class TerminalPortalView: NSView {
    /// A terminal (`surface`) or a code tab (`code`).
    private struct Entry {
        let host: NSView
        let surface: Ghostty.SurfaceView?
        var code: CodeViewer?
        weak var anchor: NSView?
        var dropZone: DropZone?
        /// Orange ring while Claude waits for the user in this terminal.
        var ring: AttentionRingView?
    }

    /// One drop-zone preview, drawn above the terminals (Bonsplit's own is
    /// hidden behind them).
    private let dropPreview = DropPreviewView()

    private var entries: [TabID: Entry] = [:]
    private var pendingHide: Set<TabID> = []

    /// Whether this layout's item is the one on screen: selected, with no page
    /// over it, in a window that can be seen. Set by the window.
    var isOnScreen = true {
        didSet { if oldValue != isOnScreen { reposition() } }
    }
    /// The visibility last sent to each terminal, and since when it is hidden.
    private var lastVisible: [TabID: Bool] = [:]
    private var hiddenSince: [TabID: Date] = [:]

    /// Painted behind each terminal so a surface that has not drawn yet, or the
    /// strip a resize uncovers, shows the terminal's own background color.
    var terminalBackground: NSColor = .black {
        didSet {
            for entry in entries.values where entry.surface != nil {
                entry.host.layer?.backgroundColor = terminalBackground.cgColor
            }
        }
    }

    /// Whether `tab` is the one its pane shows. Bonsplit keeps every tab of a
    /// pane mounted and hides the others with opacity only, so their anchors
    /// look visible; the selection decides which terminal is drawn.
    var isTabShown: (TabID) -> Bool = { _ in true }

    /// Called when an entry that gave up the focus on hiding shows again with
    /// nothing else focused (a dragged tab whose anchor came back late), so
    /// the layout can focus it again if it is still the active tab.
    var onRefocus: ((TabID) -> Void)?
    /// Entries that dropped the focus when hidden.
    private var droppedFocus: Set<TabID> = []

    override var isFlipped: Bool { true }

    // Clicks outside a terminal reach the tab bars and dividers underneath.
    // While a tab is dragged the whole layer steps aside, as cmux's portal does,
    // so the drag reaches Bonsplit's drop zones instead of a terminal (which
    // would take the tab as text to paste).
    override func hitTest(_ point: NSPoint) -> NSView? {
        if Self.isPointerDragEvent(NSApp.currentEvent), TerminalLayout.liveTabDrag != nil { return nil }
        let hit = super.hitTest(point)
        return hit === self || hit === dropPreview ? nil : hit
    }

    /// Cheap gate before reading the drag pasteboard (a round trip to the
    /// pasteboard server); hit testing also runs for every key press.
    private static func isPointerDragEvent(_ event: NSEvent?) -> Bool {
        switch event?.type {
        case .leftMouseDragged, .leftMouseUp, .periodic: true
        case nil: NSEvent.pressedMouseButtons & 1 != 0
        default: false
        }
    }

    // MARK: Drop preview

    /// Bonsplit's active drop zone over the pane holding `tab` (nil when none).
    func setDropZone(_ zone: DropZone?, for tab: TabID) {
        guard entries[tab] != nil, entries[tab]?.dropZone != zone else { return }
        entries[tab]?.dropZone = zone
        updateDropPreview()
    }

    private func updateDropPreview() {
        let target = entries.values.first { $0.dropZone != nil && !$0.host.isHidden }
        guard let target, let zone = target.dropZone else {
            dropPreview.hide()
            return
        }
        if dropPreview.superview == nil { addSubview(dropPreview) }
        dropPreview.show(Self.previewFrame(for: zone, in: target.host.frame))
    }

    /// Same geometry as Bonsplit's own placeholder: a half for edges, the whole
    /// pane for center, inset by 4 points.
    private static func previewFrame(for zone: DropZone, in pane: NSRect) -> NSRect {
        let inset = pane.insetBy(dx: 4, dy: 4)
        switch zone {
        case .center: return inset
        case .left: return NSRect(x: inset.minX, y: inset.minY, width: pane.width / 2 - 4, height: inset.height)
        case .right: return NSRect(x: pane.midX, y: inset.minY, width: pane.width / 2 - 4, height: inset.height)
        case .top: return NSRect(x: inset.minX, y: inset.minY, width: inset.width, height: pane.height / 2 - 4)
        case .bottom: return NSRect(x: inset.minX, y: pane.midY, width: inset.width, height: pane.height / 2 - 4)
        }
    }

    /// Adds the terminal for `tab`. Its hosting view stays in this layer until removed.
    func add<Content: View>(_ tab: TabID, surface: Ghostty.SurfaceView, content: Content) {
        guard entries[tab] == nil else { return }
        let host = NSHostingView(rootView: content)
        host.wantsLayer = true
        host.layer?.backgroundColor = terminalBackground.cgColor
        host.isHidden = true
        addSubview(host, positioned: .below, relativeTo: dropPreview.superview == nil ? nil : dropPreview)
        entries[tab] = Entry(host: host, surface: surface, anchor: nil)
    }

    /// Adds the code tab for `tab`, hosted like a terminal so it keeps its state
    /// (scroll, selection) when Bonsplit rebuilds the panes.
    @discardableResult
    func add<Content: View>(_ tab: TabID, code: CodeViewer, content: Content) -> CodeTabHostView? {
        guard entries[tab] == nil else { return entries[tab]?.host as? CodeTabHostView }
        let host = CodeTabHostView(rootView: AnyView(content))
        host.wantsLayer = true
        host.updateBackground()
        host.isHidden = true
        addSubview(host, positioned: .below, relativeTo: dropPreview.superview == nil ? nil : dropPreview)
        entries[tab] = Entry(host: host, surface: nil, code: code, anchor: nil)
        return host
    }

    /// The host of the code tab `tab`.
    func codeHost(for tab: TabID) -> CodeTabHostView? {
        entries[tab]?.host as? CodeTabHostView
    }

    func remove(_ tab: TabID) {
        droppedFocus.remove(tab)
        lastVisible.removeValue(forKey: tab)
        hiddenSince.removeValue(forKey: tab)
        entries[tab]?.ring?.removeFromSuperview()
        entries.removeValue(forKey: tab)?.host.removeFromSuperview()
        updateDropPreview()
    }

    /// Called by an anchor whenever it may have moved, resized or been re-parented.
    func anchorDidChange(_ anchor: NSView, tab: TabID) {
        guard entries[tab] != nil else { return }
        if anchor.window != nil {
            entries[tab]?.anchor = anchor
            pendingHide.remove(tab)
            reposition()
        } else if entries[tab]?.anchor === anchor {
            // Bonsplit removes the old anchor before inserting the new one when it
            // rebuilds a pane. Wait a turn before hiding so the terminal stays up.
            pendingHide.insert(tab)
            DispatchQueue.main.async { [weak self] in self?.flushPendingHides() }
        }
    }

    /// Rings the terminal of `tab` (as cmux does) while something waits for the user.
    func setAttention(_ on: Bool, for tab: TabID) {
        guard entries[tab]?.surface != nil else { return }
        if on, entries[tab]?.ring == nil {
            let ring = AttentionRingView()
            addSubview(ring, positioned: .above, relativeTo: entries[tab]?.host)
            entries[tab]?.ring = ring
        } else if !on {
            entries[tab]?.ring?.removeFromSuperview()
            entries[tab]?.ring = nil
        }
        reposition()
    }

    private func flushPendingHides() {
        for tab in pendingHide where entries[tab]?.anchor?.window == nil {
            if let host = entries[tab]?.host { hide(host, tab: tab) }
        }
        pendingHide.removeAll()
    }

    override func layout() {
        super.layout()
        reposition()
    }

    /// Hides an entry. One holding the focus gives it up first: AppKit would
    /// otherwise hand it to the next key view, some other terminal (even in
    /// another item), whose focus would then move that layout's selection.
    /// Whoever hid it (tab, item or page change) focuses what comes next.
    private func hide(_ host: NSView, tab: TabID) {
        guard !host.isHidden else { return }
        if let window, let responder = window.firstResponder {
            let inHost = (responder as? NSView).map { $0 === host || $0.isDescendant(of: host) } ?? false
            if inHost || responder.enclosingCodeTabHost === host {
                window.makeFirstResponder(nil)
                droppedFocus.insert(tab)
            }
        }
        host.isHidden = true
    }

    /// Puts every terminal over its anchor. Frames change without implicit
    /// animation, and a resized terminal adopts its new size and redraws in the
    /// same pass instead of on SwiftUI's next update, as cmux's portal does.
    func reposition() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (tab, entry) in entries {
            guard let anchor = entry.anchor, anchor.window === window, !anchor.isHiddenOrHasHiddenAncestor, isTabShown(tab) else {
                if !pendingHide.contains(tab) { hide(entry.host, tab: tab) }
                continue
            }
            let frame = convert(anchor.bounds, from: anchor).integral
            // A pane mid-rebuild can report a degenerate rect; keep the last good one.
            guard frame.width >= 2, frame.height >= 2 else { continue }
            if entry.host.frame != frame {
                entry.host.frame = frame
                entry.host.layoutSubtreeIfNeeded()
                if let surface = entry.surface?.surface { ghostty_surface_refresh(surface) }
            }
            if entry.host.isHidden {
                entry.host.isHidden = false
                if droppedFocus.remove(tab) != nil, window?.firstResponder == nil || window?.firstResponder === window {
                    let refocus = onRefocus
                    DispatchQueue.main.async { refocus?(tab) }
                }
            }
        }
        for entry in entries.values {
            guard let ring = entry.ring else { continue }
            ring.isHidden = entry.host.isHidden
            ring.frame = entry.host.frame.insetBy(dx: 2, dy: 2)
        }
        updateOcclusion()
    }

    // MARK: Hidden terminals

    /// Terminals that cannot be seen stop drawing (cursor blink, output), as
    /// in cmux: libghostty skips their frames while occluded. A terminal
    /// coming back gets its GPU renderer again first, if it was reclaimed.
    private func updateOcclusion() {
        for (tab, entry) in entries {
            let visible = isOnScreen && !entry.host.isHidden && window?.occlusionState.contains(.visible) != false
            if let code = entry.code {
                if code.isOnScreen != visible { code.isOnScreen = visible }
                continue
            }
            guard lastVisible[tab] != visible, let view = entry.surface, let surface = view.surface else { continue }
            if visible {
                view.setRendererRealized(true)
                hiddenSince[tab] = nil
            } else {
                hiddenSince[tab] = Date()
            }
            ghostty_surface_set_occlusion(surface, visible)
            if visible { ghostty_surface_refresh(surface) }
            lastVisible[tab] = visible
        }
    }

    /// Frees the GPU renderer (drawables, glyph atlas: most of a terminal's
    /// memory) of terminals hidden for longer than `after`. The shell, its
    /// output and the scrollback stay; the renderer comes back when shown.
    func reclaimRenderers(hiddenLongerThan after: TimeInterval) {
        let now = Date()
        for (tab, since) in hiddenSince where now.timeIntervalSince(since) > after {
            guard let surface = entries[tab]?.surface, surface.isRendererRealized else { continue }
            surface.setRendererRealized(false)
        }
    }
}

/// Placeholder Bonsplit renders for each tab: reports where the terminal should be.
struct TerminalPortalAnchor: NSViewRepresentable {
    let tab: TabID
    weak var portal: TerminalPortalView?
    var dropZone: DropZone?

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.tab = tab
        view.portal = portal
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.tab = tab
        view.portal = portal
        view.report()
        portal?.setDropZone(dropZone, for: tab)
    }

    final class AnchorView: NSView {
        var tab: TabID?
        weak var portal: TerminalPortalView?

        func report() {
            guard let tab else { return }
            portal?.anchorDidChange(self, tab: tab)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func viewDidHide() {
            super.viewDidHide()
            report()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            report()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            report()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        // The terminal above receives the events; the anchor never should.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The translucent rectangle showing where a dragged tab will land.
private final class DropPreviewView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 2
        alphaValue = 0
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    // Never takes the drag or a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ target: NSRect) {
        let appearing = alphaValue < 0.01
        if appearing {
            // Start from the final frame so it fades in place instead of flying in.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            frame = target
            CATransaction.commit()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = appearing ? 0.12 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().frame = target
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 0
        }
    }
}

/// The attention ring: 2 pt, corner radius 6, with a soft glow, like cmux's.
final class AttentionRingView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 2
        layer?.cornerRadius = 6
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 4
        layer?.shadowOffset = .zero
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.systemOrange.cgColor
            layer?.shadowColor = NSColor.systemOrange.cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
