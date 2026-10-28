import Foundation

/// Why a terminal's Claude Code wants the user back.
enum AgentAttention: Equatable {
    /// Claude finished its turn.
    case finished
    /// Claude is waiting on a permission prompt or a question.
    case needsInput(String?)
}

/// How Deckmux terminals talk to the app: each one gets its ID, the socket
/// and the bundled `claude` wrapper ahead on `PATH`. The wrapper adds hooks
/// through `--settings` only for that launch; `~/.claude/settings.json` is
/// never touched.
enum AgentIntegration {
    static var socketPath: String {
        SessionStore.directory.appendingPathComponent("deckmux.sock").path
    }

    static var binDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
    }

    static var shellIntegrationDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("shell-integration", isDirectory: true)
    }

    /// Variables for the shell of terminal `id`.
    static func environment(forTerminal id: UUID) -> [String: String] {
        var env = [
            "DECKMUX_SURFACE_ID": id.uuidString,
            "DECKMUX_SOCKET_PATH": socketPath,
        ]
        if let bin = binDirectory {
            env["DECKMUX_BIN_DIR"] = bin.path
            env["DECKMUX_CLI"] = bin.appendingPathComponent("deckmux").path
            let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = "\(bin.path):\(path)"
        }
        if let integration = shellIntegrationDirectory {
            env["DECKMUX_SHELL_INTEGRATION_DIR"] = integration.path
        }
        return env
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
