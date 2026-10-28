import Foundation

/// Points libghostty at the themes and terminfo bundled with Deckmux, the same
/// way cmux does in `configureGhosttyEnvironment`.
enum GhosttyEnvironment {
    static func configure() {
        removeInheritedAgentSession()
        removeInheritedCmuxTerminal()
        guard let resources = Bundle.main.resourceURL else { return }
        let ghosttyDir = resources.appendingPathComponent("ghostty")
        let fm = FileManager.default
        if fm.fileExists(atPath: ghosttyDir.appendingPathComponent("themes").path) {
            setenv("GHOSTTY_RESOURCES_DIR", ghosttyDir.path, 1)
        }
        // Must sit next to the resources dir: libghostty derives TERMINFO from it.
        let terminfo = resources.appendingPathComponent("terminfo")
        if getenv("TERMINFO") == nil, fm.fileExists(atPath: terminfo.path) {
            setenv("TERMINFO", terminfo.path, 1)
        }
        setenv("TERM_PROGRAM", "Deckmux", 1)
        if getenv("COLORTERM") == nil { setenv("COLORTERM", "truecolor", 1) }
        let dataDirs = getenv("XDG_DATA_DIRS").map { String(cString: $0) } ?? "/usr/local/share:/usr/share"
        setenv("XDG_DATA_DIRS", "\(resources.path):\(dataDirs)", 1)
    }

    /// When Deckmux is launched from inside a Claude Code session, that session's
    /// variables would reach every terminal and make `claude` there run as a
    /// child session (no transcript, wrong session id, the parent's socket token).
    private static func removeInheritedAgentSession() {
        let exact: Set<String> = ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "AI_AGENT"]
        for name in ProcessInfo.processInfo.environment.keys
        where exact.contains(name) || name.hasPrefix("CLAUDE_CODE_") {
            unsetenv(name)
        }
    }

    /// Launched from a cmux terminal, Deckmux would hand that terminal's
    /// identity to its own shells, and cmux's claude wrapper (first on PATH)
    /// would report Deckmux sessions to cmux.
    private static func removeInheritedCmuxTerminal() {
        let environment = ProcessInfo.processInfo.environment
        for name in environment.keys where name.hasPrefix("CMUX") { unsetenv(name) }
        guard let path = environment["PATH"] else { return }
        let kept = path.split(separator: ":").filter { !$0.hasSuffix("/cmux.app/Contents/Resources/bin") }
        setenv("PATH", kept.joined(separator: ":"), 1)
    }
}
