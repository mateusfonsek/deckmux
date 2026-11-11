import Foundation

/// Runs a command to completion and returns its status and output. The café's
/// commands are short (sudo, pmset, osascript), so waiting is fine.
enum SystemProcess {
    struct Result {
        var status: Int32
        var output: String
        var succeeded: Bool { status == 0 }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Result(status: process.terminationStatus, output: output)
    }

    /// `sudo -n pmset -a disablesleep <0|1>`: never asks for a password; it
    /// works only with the café's sudoers rule.
    @discardableResult
    static func disableSleep(_ disabled: Bool) -> Result {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"])
    }
}
