import AppKit
import SwiftUI

/// Deckmux's design tokens. Color means workspace: the app
/// itself stays graphite and neutral, and the strong colors are the
/// workspaces', the same in the sidebar, tabs, cards and meetings.
enum Theme {
    // MARK: Sizes

    /// The strip at the top: traffic lights over the sidebar, clock and next
    /// meeting over the content. Matches the unified compact titlebar.
    static let topBarHeight: CGFloat = 40
    static let sidebarWidth: CGFloat = 264
    static let tabBarHeight: CGFloat = 34
    static let tabTitleSize: CGFloat = 12
    static let tabMinWidth: CGFloat = 150
    static let tabMaxWidth: CGFloat = 260

    enum Radius {
        static let row: CGFloat = 7
        static let card: CGFloat = 8
        static let panel: CGFloat = 12
    }

    // MARK: Type

    enum Font {
        static let largeTitle = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let rowTitle = SwiftUI.Font.system(size: 13, weight: .medium)
        static let body = SwiftUI.Font.system(size: 13)
        static let secondary = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 11)
        static let section = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
    }

    // MARK: Colors

    /// The neutral accent (graphite), from `AccentColor` in the asset catalog.
    static let accent = Color(nsColor: .controlAccentColor)
    /// Claude Code's orange: ✳ and everything about the agent.
    static let claude = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    /// Something waits for the user (bell, "esperando você", attention ring).
    static let attention = Color(nsColor: .systemOrange)
    static let now = Color(nsColor: .systemRed)

    /// How a workspace color is laid under content: selection, washes.
    static let selectionOpacity = 0.18
    static let washOpacity = 0.10
}

extension Color {
    /// The app's neutral accent. SwiftUI's `accentColor` ignores
    /// `NSAccentColorName` in this SwiftPM-built app; AppKit's does not.
    static let deckAccent = Theme.accent

    /// Claude's brand orange.
    static let claude = Theme.claude
}
