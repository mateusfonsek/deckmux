import AppKit
import Carbon

/// A system-wide shortcut that brings the Deckmux window to the front from any
/// app, or hides Deckmux when it is already in front. Carbon hot
/// keys need no Accessibility permission. Presets only, none of them a
/// combination the system or the app already uses (⌃⌘Space is the emoji
/// picker, ⌥⌘Space the Finder search, ⌘⇧D a split).
@MainActor
final class GlobalHotkey {
    enum Preset: String, CaseIterable {
        case controlOptionSpace
        case controlShiftSpace
        case controlOptionD
        case controlOptionT
        case none

        static let `default` = Preset.controlOptionSpace

        var title: String {
            switch self {
            case .controlOptionSpace: "⌃⌥ Espaço"
            case .controlShiftSpace: "⌃⇧ Espaço"
            case .controlOptionD: "⌃⌥ D"
            case .controlOptionT: "⌃⌥ T"
            case .none: "Nenhum"
            }
        }

        var keyCode: UInt32? {
            switch self {
            case .controlOptionSpace, .controlShiftSpace: UInt32(kVK_Space)
            case .controlOptionD: UInt32(kVK_ANSI_D)
            case .controlOptionT: UInt32(kVK_ANSI_T)
            case .none: nil
            }
        }

        var carbonModifiers: UInt32 {
            switch self {
            case .controlOptionSpace, .controlOptionD, .controlOptionT: UInt32(controlKey | optionKey)
            case .controlShiftSpace: UInt32(controlKey | shiftKey)
            case .none: 0
            }
        }

        /// For showing the shortcut on a menu item.
        var keyEquivalent: String {
            switch self {
            case .controlOptionSpace, .controlShiftSpace: " "
            case .controlOptionD: "d"
            case .controlOptionT: "t"
            case .none: ""
            }
        }

        var modifierFlags: NSEvent.ModifierFlags {
            switch self {
            case .controlOptionSpace, .controlOptionD, .controlOptionT: [.control, .option]
            case .controlShiftSpace: [.control, .shift]
            case .none: []
            }
        }
    }

    nonisolated private static let defaultsKey = "globalHotkey"

    nonisolated static var preset: Preset {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Preset.init(rawValue:)) ?? .default }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// The one hot key of the app; the Carbon callback cannot capture anything.
    private static var shared: GlobalHotkey?

    private let action: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
        Self.shared = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotkey.shared?.action() } }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, &handler)
        apply(Self.preset)
    }

    /// Registers `preset` (unregistering the previous one) and remembers it.
    func apply(_ preset: Preset) {
        Self.preset = preset
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        guard let keyCode = preset.keyCode else { return }
        let id = EventHotKeyID(signature: 0x444B_4D58, id: 1) // "DKMX"
        let status = RegisterEventHotKey(keyCode, preset.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { NSLog("Deckmux: could not register the global hotkey (%d)", status) }
    }
}
