import Foundation

/// Where the files a workspace touches outside its own folder live.
/// `DECKMUX_CONFIG_HOME` points all of them at another folder, so tests never
/// write to the real Claude Code configuration.
enum ConfigPaths {
    static var home: URL {
        if let override = ProcessInfo.processInfo.environment["DECKMUX_CONFIG_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    static var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    static var claudeState: URL { home.appendingPathComponent(".claude.json") }
    static var claudeThemes: URL { home.appendingPathComponent(".claude/themes", isDirectory: true) }
    static var workspaceGuide: URL { home.appendingPathComponent(".claude/workspace.md") }
    static var googleCredentials: URL { home.appendingPathComponent(".config/google-workspace-mcp", isDirectory: true) }
    static var mcpAccounts: URL { home.appendingPathComponent(".config/claude-statusline/mcp-accounts.json") }

    static func theme(slug: String) -> URL { claudeThemes.appendingPathComponent("\(slug).json") }
    static func googleFolder(slug: String) -> URL { googleCredentials.appendingPathComponent(slug, isDirectory: true) }

    /// `~/…` for display.
    static func display(_ url: URL) -> String {
        let path = url.path
        let homePath = home.path
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }
}
