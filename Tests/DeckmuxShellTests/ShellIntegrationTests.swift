import Foundation
import Testing

/// The zsh integration Deckmux terminals load (Resources/shell-integration),
/// run in a real interactive zsh with a user's .zshrc.
private let integration = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/shell-integration/deckmux-zsh-integration.zsh")

/// Runs `commands` in an interactive zsh shaped like a Deckmux terminal: the
/// integration sourced from .zshenv (as Ghostty's bootstrap does), then the
/// given .zshrc. Two fake `claude` executables print who answered.
private func runInDeckmuxShell(zshrc: String, commands: String) throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("deckmux-zsh-\(UUID().uuidString)")
    let fm = FileManager.default
    for (dir, label) in [("wrapper", "WRAPPER"), ("real", "REAL")] {
        let folder = root.appendingPathComponent(dir)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("claude")
        try "#!/bin/sh\necho \(label) \"$@\"\n".write(to: file, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    let zdot = root.appendingPathComponent("zdot")
    try fm.createDirectory(at: zdot, withIntermediateDirectories: true)
    try "source '\(integration.path)'\n".write(to: zdot.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
    try zshrc.replacingOccurrences(of: "@REAL@", with: root.appendingPathComponent("real").path)
        .write(to: zdot.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-i"]
    let wrapper = root.appendingPathComponent("wrapper").path
    process.environment = [
        "HOME": root.path, "ZDOTDIR": zdot.path, "TERM": "dumb",
        "DECKMUX_BIN_DIR": wrapper, "PATH": "\(wrapper):/usr/bin:/bin",
    ]
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    input.fileHandleForWriting.write(Data((commands + "\nexit\n").utf8))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try? fm.removeItem(at: root)
    return String(decoding: data, as: UTF8.self)
}

/// A user's own `claude` function calling `command claude`, with another
/// claude put first on PATH by .zshrc: the command still reaches the
/// wrapper (which adds the hooks), with the function's arguments.
@Test func userFunctionCallingCommandClaudeStillGoesThroughWrapper() throws {
    let output = try runInDeckmuxShell(zshrc: """
        path=(@REAL@ $path)
        claude() { command claude --plugin-dir tools "$@" }
        """, commands: "claude hello")
    #expect(output.contains("WRAPPER --plugin-dir tools hello"))
    #expect(!output.contains("REAL"))
}

/// No function of the user's: plain `claude` reaches the wrapper too.
@Test func plainClaudeGoesThroughWrapper() throws {
    let output = try runInDeckmuxShell(zshrc: "path=(@REAL@ $path)\n", commands: "claude hi")
    #expect(output.contains("WRAPPER hi"))
}
