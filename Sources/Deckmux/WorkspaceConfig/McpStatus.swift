import DeckmuxShell
import Foundation

/// The user's shell PATH. Opened from the Finder, Deckmux inherits launchd's
/// minimal PATH, without `claude`, `uvx` or `npx`; `.zshrc` adds them.
enum UserShell {
    /// The one lookup, shared: callers that ask while it runs (restored code
    /// tabs, all at once) wait for the same `zsh -ilc`.
    private static let lock = NSLock()
    private static var pathTask: Task<String, Never>?

    static func path() async -> String {
        let task = lock.withLock {
            if let pathTask { return pathTask }
            let task = Task.detached(priority: .userInitiated) { await resolvePath() }
            pathTask = task
            return task
        }
        return await task.value
    }

    /// `name` on the user's PATH. When it is missing, the PATH is read again
    /// once: it may have been installed after Deckmux opened.
    static func find(_ name: String) async -> String? {
        if let found = Executables.find(name, inPath: await path(), skipping: AgentIntegration.binDirectory?.path) { return found }
        lock.withLock { pathTask = nil }
        return Executables.find(name, inPath: await path(), skipping: AgentIntegration.binDirectory?.path)
    }

    private static func resolvePath() async -> String {
        let output = await run("/bin/zsh", ["-ilc", "print -r -- \"$PATH\""], in: nil, path: nil)
        let path = output.stdout.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return (path?.isEmpty == false ? path : nil) ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    }

    struct Output {
        var stdout: String
        var stderr: String
        var status: Int32
    }

    /// Runs a program off the main thread and collects its output.
    static func run(_ executable: String, _ arguments: [String], in folder: URL?, path: String?, timeout: TimeInterval = 90) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let folder { process.currentDirectoryURL = folder }
                var env = ProcessInfo.processInfo.environment
                if let path { env["PATH"] = path }
                env["NO_COLOR"] = "1"
                process.environment = env
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: Output(stdout: "", stderr: error.localizedDescription, status: -1))
                    return
                }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                // Read before waiting: a full pipe would block the child.
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                continuation.resume(returning: Output(
                    stdout: String(decoding: stdout, as: UTF8.self),
                    stderr: String(decoding: stderr, as: UTF8.self),
                    status: process.terminationStatus
                ))
            }
        }
    }

    /// The `claude` executable on the user's PATH (never Deckmux's wrapper).
    static func claudeExecutable(path: String) -> String? {
        Executables.find("claude", inPath: path, skipping: AgentIntegration.binDirectory?.path)
    }
}

/// The health of one MCP server, as `claude mcp list` reports it.
enum McpHealth: Equatable {
    case checking
    case connected
    case needsLogin
    case failed(String)
    /// Not listed (Claude Code ignores servers it has not been asked to approve).
    case unknown
}

enum McpStatusChecker {
    /// Runs `claude mcp list` in the workspace root, where its `.mcp.json`
    /// applies, and returns the health of each server by name.
    static func check(root: URL) async -> Result<[String: McpHealth], ApplyError> {
        let path = await UserShell.path()
        guard let claude = UserShell.claudeExecutable(path: path) else {
            return .failure(ApplyError(message: ClaudeCodeSetup.missingMessage))
        }
        let output = await UserShell.run(claude, ["mcp", "list"], in: root, path: path)
        guard output.status == 0 || !output.stdout.isEmpty else {
            return .failure(ApplyError(message: output.stderr.isEmpty ? "claude mcp list falhou." : output.stderr))
        }
        return .success(parse(output.stdout))
    }

    /// Lines look like `slack-acme: https://mcp.slack.com/mcp (HTTP) - ✔ Connected`.
    static func parse(_ text: String) -> [String: McpHealth] {
        var result: [String: McpHealth] = [:]
        for line in text.split(separator: "\n").map(String.init) {
            guard let colon = line.firstIndex(of: ":"), let dash = line.range(of: " - ", options: .backwards) else { continue }
            let name = String(line[..<colon])
            guard !name.contains(" ") else { continue }
            let status = line[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            if status.contains("Connected") {
                result[name] = .connected
            } else if status.localizedCaseInsensitiveContains("auth") {
                result[name] = .needsLogin
            } else {
                let message = status.replacingOccurrences(of: "✗", with: "").trimmingCharacters(in: .whitespaces)
                result[name] = .failed(message)
            }
        }
        return result
    }
}

/// Which account each MCP server is logged into.
enum McpAccounts {
    /// From `~/.config/claude-statusline/mcp-accounts.json` (Slack, ClickUp…)
    /// and, for Google, the token file name in the workspace's credentials.
    static func account(for server: String, slug: String) -> String? {
        if McpKind.of(serverName: server) == .google {
            return googleAccount(slug: slug)
        }
        guard let text = try? String(contentsOf: ConfigPaths.mcpAccounts, encoding: .utf8),
              let json = try? JSONValue(parsing: text), let entry = json[server] else { return nil }
        let email = entry["email"]?.stringValue
        let workspace = entry["workspace"]?.stringValue
        return [email, workspace.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }

    static func googleAccount(slug: String) -> String? {
        let folder = ConfigPaths.googleFolder(slug: slug).appendingPathComponent("credentials")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.filter { $0.hasSuffix(".json") && $0.contains("@") }.map { String($0.dropLast(5)) }.sorted().first
    }
}
