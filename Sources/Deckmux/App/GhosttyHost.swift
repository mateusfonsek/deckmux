import AppKit

/// What the vendored Ghostty code asks of the window controller hosting its
/// surfaces. Stands in for Ghostty's `BaseTerminalController`, so Deckmux's
/// own tabs and splits decide how these actions behave.
protocol GhosttyTerminalHost: AnyObject {
    var isSplit: Bool { get }
    var hasMultipleTabs: Bool { get }
    var focusedSurface: Ghostty.SurfaceView? { get }
    var commandPaletteIsShowing: Bool { get }
    var focusFollowsMouse: Bool { get }
    var titleOverride: String? { get set }
    func canMoveFocus(_ direction: Ghostty.SplitFocusDirection, from surface: Ghostty.SurfaceView) -> Bool
    func toggleBackgroundOpacity()
    func promptTabTitle()
}

/// Fullscreen styles named by Ghostty's config; Deckmux uses native fullscreen only.
enum FullscreenMode: String, Codable {
    case native
    case nonNative
    case nonNativeVisibleMenu
    case nonNativePaddedNotch
}

enum TerminalRestoreError: Error {
    case delegateInvalid
    case identifierUnknown
    case stateDecodeFailed
    case windowDidNotLoad
}
