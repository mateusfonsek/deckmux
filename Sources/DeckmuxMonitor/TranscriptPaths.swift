import Foundation

/// Where Claude Code keeps a conversation's files under `~/.claude/projects`.
public enum TranscriptPaths {
    /// The project folder's name for a working directory: every character
    /// that is not an ASCII letter or digit becomes "-", so
    /// "/Users/f/src/github.com/MateusFonseK/fonsek.dev" is
    /// "-Users-f-src-github-com-MateusFonseK-fonsek-dev".
    public static func projectFolderName(cwd: String) -> String {
        String(cwd.unicodeScalars.map { scalar -> Character in
            let isAlphanumeric = (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
            return isAlphanumeric ? Character(scalar) : "-"
        })
    }

    /// `<claudeHome>/projects/<folder>/<sessionID>/subagents`.
    public static func subagentsFolder(claudeHome: URL, cwd: String, sessionID: String) -> URL {
        claudeHome.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectFolderName(cwd: cwd), isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
    }
}
