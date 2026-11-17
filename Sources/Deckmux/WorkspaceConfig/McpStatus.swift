import DeckmuxAgents
import DeckmuxJSON
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

    /// An executable on the user's PATH (never Deckmux's `claude` wrapper).
    static func executable(_ name: String, path: String) -> String? {
        Executables.find(name, inPath: path, skipping: AgentIntegration.binDirectory?.path)
    }
}

enum McpStatusChecker {
    /// Runs each agent's MCP list command in the workspace root, where its
    /// files apply, and returns each server's health by agent.
    static func check(root: URL, agents: [AgentKind]) async -> [AgentKind: Result<[String: McpHealth], ApplyError>] {
        let path = await UserShell.path()
        var results: [AgentKind: Result<[String: McpHealth], ApplyError>] = [:]
        for kind in agents {
            let provider = AgentRegistry.provider(for: kind)
            guard let mcp = provider.mcp else { continue }
            guard let executable = UserShell.executable(provider.executable, path: path) else {
                results[kind] = .failure(ApplyError(message: AgentSetup.missingMessage(kind)))
                continue
            }
            let output = await UserShell.run(executable, mcp.listArguments, in: root, path: path)
            if output.status != 0 && output.stdout.isEmpty && mcp.health(stdout: "", stderr: output.stderr).isEmpty {
                let command = ([provider.executable] + mcp.listArguments).joined(separator: " ")
                results[kind] = .failure(ApplyError(message: output.stderr.isEmpty ? "\(command) falhou." : output.stderr))
            } else {
                results[kind] = .success(mcp.health(stdout: output.stdout, stderr: output.stderr))
            }
        }
        return results
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
