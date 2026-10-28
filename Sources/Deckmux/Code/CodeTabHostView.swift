import AppKit
import SwiftUI

/// A terminal shortcut pressed in a code tab. In a terminal these come from
/// Ghostty's keybindings; a code tab has no Ghostty surface, so it reads the
/// keys itself.
enum CodeTabShortcut: Equatable {
    case close
    case newTab
    case splitRight
    case splitDown
    case focus(Ghostty.SplitFocusDirection)
    /// ⌃1–⌃9, counting from 1.
    case gotoTab(Int)
    case previousTab
    case nextTab
    case zoom

    init?(_ event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch mods {
        case [.command]:
            switch key {
            case "w": self = .close
            case "t": self = .newTab
            case "d": self = .splitRight
            default: return nil
            }
        case [.command, .shift]:
            // Shift may or may not be folded into the character, and brackets
            // depend on the keyboard layout; the key code catches the rest.
            if key == "d" { self = .splitDown }
            else if key == "[" || key == "{" || event.keyCode == 33 { self = .previousTab }
            else if key == "]" || key == "}" || event.keyCode == 30 { self = .nextTab }
            else if event.keyCode == 36 || event.keyCode == 76 { self = .zoom }
            else { return nil }
        case [.command, .option]:
            switch event.specialKey {
            case .leftArrow?: self = .focus(.left)
            case .rightArrow?: self = .focus(.right)
            case .upArrow?: self = .focus(.up)
            case .downArrow?: self = .focus(.down)
            default: return nil
            }
        case [.control]:
            let digitKeyCodes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
            if let number = Int(key), (1...9).contains(number) { self = .gotoTab(number) }
            else if let number = digitKeyCodes[event.keyCode] { self = .gotoTab(number) }
            else { return nil }
        default:
            return nil
        }
    }
}

/// Hosts a code tab in the portal. Takes keyboard focus like a terminal, so
/// the layout knows which tab is active, and turns the terminal shortcuts into
/// the layout's actions for its tab. Everything else (⌘N, ⌘0, ⌘1–9, ⌘⇧P)
/// goes on to the menu.
final class CodeTabHostView: NSHostingView<AnyView> {
    /// Called with each terminal shortcut pressed while focus is in this tab.
    var onShortcut: ((CodeTabShortcut) -> Void)?
    /// Called when this view, or a view inside it, becomes the first
    /// responder (reported by the window, which sees every change).
    var onFocus: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    /// Whether the window's keyboard focus is this view or a view inside it.
    /// SwiftUI may hand the focus to its own key-view proxy, a responder
    /// that is not a subview, so this follows the responder chain.
    var hasFocus: Bool { window?.firstResponder?.enclosingCodeTabHost === self }

    // The window offers key equivalents to every view, focused or not.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if hasFocus, let shortcut = CodeTabShortcut(event) {
            onShortcut?(shortcut)
            return true
        }
        if hasFocus, isFind(event), showFindBar() { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func isFind(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command]
            && event.charactersIgnoringModifiers?.lowercased() == "f"
    }

    /// ⌘F with the focus elsewhere in the tab (the tree, the list, the tab
    /// itself) opens the find bar of the reader on screen; the reader and its
    /// find bar answer ⌘F themselves. In a side-by-side diff, the new side.
    private func showFindBar() -> Bool {
        if let responder = window?.firstResponder as? NSView,
           responder is ReaderTextView || responder.enclosingView(of: CodeTextView.self) != nil {
            return false
        }
        var readers: [ReaderTextView] = []
        func collect(_ view: NSView) {
            if view.isHidden { return }
            if let reader = view as? ReaderTextView, reader.visibleRect.width > 0 { readers.append(reader) }
            view.subviews.forEach(collect)
        }
        collect(self)
        guard let reader = readers.last, let window else { return false }
        window.makeFirstResponder(reader)
        reader.finderAction(.showFindInterface)
        return true
    }

    // ⌃1–⌃9 may arrive as a plain key press.
    override func keyDown(with event: NSEvent) {
        if let shortcut = CodeTabShortcut(event) {
            onShortcut?(shortcut)
            return
        }
        super.keyDown(with: event)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// The window background, resolved for this view's appearance; again on
    /// every light/dark switch (a `cgColor` keeps the appearance it was made in).
    func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    /// Sees every click in the window before it is dispatched.
    private var clickMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard window != nil else { return }
        // Native controls (the Arquivos/Alterações picker, the header's
        // buttons, the column's resize handle) track the click themselves and
        // never pass it to `mouseDown` below. After any click inside the tab
        // the tab takes the focus, unless something in it already has it.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window, !self.isHiddenOrHasHiddenAncestor,
                  let content = window.contentView, let frame = content.superview,
                  let hit = content.hitTest(frame.convert(event.locationInWindow, from: nil)),
                  hit === self || hit.isDescendant(of: self) else { return event }
            // After the control has handled the click (its tracking loop
            // runs in the event-tracking mode; this waits for the default one).
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                guard let self, let window = self.window, !self.isHiddenOrHasHiddenAncestor, !self.hasFocus else { return }
                window.makeFirstResponder(self)
            }
            return event
        }
    }

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    // A click anywhere in the tab focuses it, so ⌘W and the others act on
    // this tab and not on the terminal that had focus before.
    // SwiftUI's handling of the click moves the focus to the Bonsplit panes'
    // focusable container underneath, so the tab takes it after.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if !hasFocus { window?.makeFirstResponder(self) }
    }

    // Empty areas of the SwiftUI content still belong to the tab.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point) { return hit }
        return !isHidden && frame.contains(point) ? self : nil
    }
}

extension NSView {
    /// The nearest enclosing view of type `T`, up the superviews.
    func enclosingView<T: NSView>(of type: T.Type) -> T? {
        var view = superview
        while let current = view {
            if let match = current as? T { return match }
            view = current.superview
        }
        return nil
    }
}

extension NSResponder {
    /// The code tab this responder belongs to, if any: up the superviews for a
    /// view, up the responder chain for SwiftUI's key-view proxy.
    var enclosingCodeTabHost: CodeTabHostView? {
        var responder: NSResponder? = self
        while let current = responder {
            if let host = current as? CodeTabHostView { return host }
            responder = (current as? NSView)?.superview ?? current.nextResponder
        }
        return nil
    }
}
