#if DEBUG
import AppKit
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
