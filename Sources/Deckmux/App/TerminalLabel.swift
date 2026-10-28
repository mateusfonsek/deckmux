import Foundation

enum TerminalLabel {
    /// A terminal's folder as shown in tabs and the sidebar: its last path
    /// component, or "~" for the home folder (also when not known yet, since
    /// that is where a shell starts).
    static func folderName(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "~" }
        let standardized = (path as NSString).standardizingPath
        return standardized == NSHomeDirectory() ? "~" : (standardized as NSString).lastPathComponent
    }

    /// A tab's name. While Claude Code runs in the terminal it is the title
    /// Claude gives the conversation, as in cmux ("✳ Ajustar o login", with a
    /// spinner in front while it works); otherwise the folder name.
    static func tabName(pwd: String?, title: String, runsClaude: Bool) -> String {
        if runsClaude, let session = claudeTitle(title) { return session }
        return folderName(pwd)
    }

    /// Claude Code's title without the status glyph in front, for places
    /// that show their own Claude symbol (the sidebar).
    static func plainName(pwd: String?, title: String, runsClaude: Bool) -> String {
        guard runsClaude, let session = claudeTitle(title) else { return folderName(pwd) }
        return withoutStatusGlyph(session)
    }

    private static func claudeTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether Claude in this terminal is working: it says so over OSC 7501
    /// (Claude Code 2.1.3xx, which then leaves the spinner out of the title),
    /// or, in older versions, by the title.
    @MainActor static func isWorking(_ surface: Ghostty.SurfaceView) -> Bool {
        surface.reportsWorking || isWorking(surface.title)
    }

    /// Claude Code puts ✳ before its title when idle and a spinner frame
    /// while it works.
    static func isWorking(_ title: String) -> Bool {
        guard let first = title.trimmingCharacters(in: .whitespaces).unicodeScalars.first else { return false }
        return first != "✳" && !CharacterSet.alphanumerics.contains(first) && withoutStatusGlyph(title) != title
    }

    /// Drops the leading "✳ " or spinner character Claude Code puts before
    /// its title.
    static func withoutStatusGlyph(_ title: String) -> String {
        guard let first = title.unicodeScalars.first,
              !CharacterSet.alphanumerics.contains(first),
              let space = title.firstIndex(of: " "),
              title.distance(from: title.startIndex, to: space) <= 2 else { return title }
        let rest = title[title.index(after: space)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? title : rest
    }
}

/// Reads the branch from `.git/HEAD` (walking up to the repo root), without
/// running git. A worktree's `.git` file points at its own HEAD.
enum GitBranch {
    static func current(in path: String?) -> String? {
        guard let path else { return nil }
        var url = URL(fileURLWithPath: path).standardizedFileURL
        let fm = FileManager.default
        while url.path != "/" {
            let git = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                var head = git.appendingPathComponent("HEAD")
                if !isDirectory.boolValue,
                   let pointer = try? String(contentsOf: git, encoding: .utf8),
                   let dir = pointer.components(separatedBy: "gitdir:").last?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    head = URL(fileURLWithPath: dir, relativeTo: url).appendingPathComponent("HEAD")
                }
                guard let text = try? String(contentsOf: head, encoding: .utf8) else { return nil }
                let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("ref: refs/heads/") { return String(line.dropFirst("ref: refs/heads/".count)) }
                return String(line.prefix(7))
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
