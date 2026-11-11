import Foundation

/// The exact commands the café runs as root. Pure strings, so they can be tested.
public enum SystemCommands {
    public static let sudoersPath = "/etc/sudoers.d/deckmux"
    public static let pmset = "/usr/bin/pmset"

    /// Only plain account names go into the sudoers file or a root shell.
    public static func isSafeUser(_ user: String) -> Bool {
        !user.isEmpty && user.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
        }
    }

    /// Lets `user` turn sleep off and on, and nothing else.
    public static func sudoersLine(user: String) -> String? {
        guard isSafeUser(user) else { return nil }
        return "\(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 0, \(pmset) -a disablesleep 1"
    }

    /// Run as root: writes the rule to a temporary file, checks it with visudo
    /// and only then installs it, owned by root:wheel, mode 0440.
    public static func installScript(user: String) -> String? {
        guard let line = sudoersLine(user: user) else { return nil }
        return "tmp=$(/usr/bin/mktemp /tmp/deckmux-sudoers.XXXXXX)"
            + " && /usr/bin/printf '%s\\n' '\(line)' > \"$tmp\""
            + " && /usr/sbin/visudo -cf \"$tmp\""
            + " && /usr/sbin/chown root:wheel \"$tmp\""
            + " && /bin/chmod 0440 \"$tmp\""
            + " && /bin/mv -f \"$tmp\" \(sudoersPath)"
    }

    public static let removeScript = "/bin/rm -f \(sudoersPath)"

    /// For `/bin/sh -c`, with Deckmux's PID as $1: once Deckmux is gone, sleep
    /// comes back, even after a crash.
    public static let watcherScript =
        "trap '' HUP; while kill -0 \"$1\" 2>/dev/null; do sleep 5; done; sudo -n \(pmset) -a disablesleep 0"
}
