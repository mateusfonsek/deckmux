import GhosttyKit

/// Ghostty settings where Deckmux differs from Ghostty's defaults. Loaded before
/// the user's config files, so any of them can still be overridden there.
enum DeckmuxGhosttyDefaults {
    static let contents = """
    # Splits resize terminals in place; Ghostty's "cols x rows" overlay would flash on every split.
    resize-overlay = never
    # Same default theme as cmux when the user's config sets none: Ghostty's
    # own palette has a yellowish green (color 2 = #b9ca4a).
    theme = light:Apple System Colors Light,dark:Apple System Colors
    # ⌘0 opens Hoje (menu Janela) instead of resetting the font size.
    keybind = cmd+0=unbind
    # As in cmux: ⌘1…⌘9 pick sidebar items (menu Janela) and ⌃1…⌃9 pick tabs.
    keybind = cmd+1=unbind
    keybind = ctrl+1=goto_tab:1
    keybind = cmd+2=unbind
    keybind = ctrl+2=goto_tab:2
    keybind = cmd+3=unbind
    keybind = ctrl+3=goto_tab:3
    keybind = cmd+4=unbind
    keybind = ctrl+4=goto_tab:4
    keybind = cmd+5=unbind
    keybind = ctrl+5=goto_tab:5
    keybind = cmd+6=unbind
    keybind = ctrl+6=goto_tab:6
    keybind = cmd+7=unbind
    keybind = ctrl+7=goto_tab:7
    keybind = cmd+8=unbind
    keybind = ctrl+8=goto_tab:8
    keybind = cmd+9=unbind
    keybind = ctrl+9=goto_tab:9
    # ⌘⇧P is Deckmux's command palette, not Ghostty's.
    keybind = cmd+shift+p=unbind
    """

    static func load(into config: ghostty_config_t) {
        let label = "deckmux-defaults"
        contents.utf8CString.withUnsafeBufferPointer { buffer in
            // utf8CString includes the trailing NUL; the length excludes it.
            ghostty_config_load_string(config, buffer.baseAddress!, UInt(buffer.count - 1), label)
        }
    }
}

/// The system appearance last reported to libghostty; new terminals start with it.
enum GhosttyAppearance {
    static var scheme = GHOSTTY_COLOR_SCHEME_DARK
}
