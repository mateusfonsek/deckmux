import AppKit
import SwiftUI

/// Deckmux → Ajustes… (⌘,). One window per app.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let model = AgentsSettingsModel()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        window.title = "Ajustes"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let hosting = NSHostingController(rootView: AgentsSettingsView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        window.center()
        window.setFrameAutosaveName("DeckmuxSettings")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.refresh()
    }
}
