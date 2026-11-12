import DeckmuxCaffeine
import Foundation

/// The sudoers rule that lets Deckmux run `pmset -a disablesleep 0|1`
/// without a password. Installed once, with the user's admin password.
enum SudoersRule {
    enum Failure: Error { case unsafeUser, failed(String) }

    /// The file itself, not `sudo -l`: a cached sudo password would make
    /// `sudo -n -l` say yes without the rule.
    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: SystemCommands.sudoersPath)
    }

    /// false: the user cancelled the password prompt.
    static func install() throws -> Bool {
        guard let script = SystemCommands.installScript(user: NSUserName()) else { throw Failure.unsafeUser }
        return try runAsAdmin(script, prompt: "O Deckmux precisa da sua senha para manter o Mac acordado com a tampa fechada.")
    }

    /// false: the user cancelled the password prompt.
    static func remove() throws -> Bool {
        try runAsAdmin(SystemCommands.removeScript, prompt: "O Deckmux precisa da sua senha para remover a permissão do café.")
    }

    private static func runAsAdmin(_ script: String, prompt: String) throws -> Bool {
        let source = "do shell script \"\(appleScriptEscaped(script))\" with prompt \"\(appleScriptEscaped(prompt))\" with administrator privileges"
        let result = SystemProcess.run("/usr/bin/osascript", ["-e", source])
        if result.succeeded { return true }
        if result.output.contains("-128") { return false }   // User canceled.
        throw Failure.failed(result.output)
    }

    private static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
