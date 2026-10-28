import Foundation

/// One line of a hunk, without its leading marker.
public enum DiffLine: Equatable, Sendable { case context(String), removed(String), added(String) }

public struct Hunk: Equatable, Sendable {
    public var oldStart: Int
    public var newStart: Int
    public var lines: [DiffLine]

    public init(oldStart: Int, newStart: Int, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.newStart = newStart
        self.lines = lines
    }
}

/// Parsed output of `git diff --no-color -U999999 -- <file>`.
public struct UnifiedDiff: Equatable, Sendable {
    public var hunks: [Hunk]
    public var isBinary: Bool

    public init(hunks: [Hunk], isBinary: Bool) {
        self.hunks = hunks
        self.isBinary = isBinary
    }

    private static func splitLines(_ text: String) -> [String] {
        // Split on unicode scalars: "\r\n" is a single Character and would not match "\n".
        var lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// Parses `@@ -a,b +c,d @@`, returning a and c.
    private static func starts(_ header: String) -> (Int, Int)? {
        let parts = header.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func first(_ s: Substring) -> Int? { Int(s.dropFirst().split(separator: ",").first ?? "") }
        guard let a = first(parts[1]), let c = first(parts[2]) else { return nil }
        return (a, c)
    }

    public static func parse(_ text: String) -> UnifiedDiff {
        var result = UnifiedDiff(hunks: [], isBinary: false)
        var current: Hunk?
        for line in splitLines(text) {
            if line.hasPrefix("@@") {
                if let h = current { result.hunks.append(h) }
                if let (a, c) = starts(line) {
                    current = Hunk(oldStart: a, newStart: c, lines: [])
                } else {
                    current = nil
                }
                continue
            }
            guard current != nil else {
                if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") { result.isBinary = true }
                continue
            }
            switch line.first {
            case " ": current?.lines.append(.context(String(line.dropFirst())))
            case "-": current?.lines.append(.removed(String(line.dropFirst())))
            case "+": current?.lines.append(.added(String(line.dropFirst())))
            default: break // "\ No newline at end of file" and anything unexpected
            }
        }
        if let h = current { result.hunks.append(h) }
        return result
    }

    /// Diff for an untracked file: every line is an addition.
    public static func allAdded(_ text: String) -> UnifiedDiff {
        let lines = splitLines(text)
        if lines.isEmpty { return UnifiedDiff(hunks: [], isBinary: false) }
        return UnifiedDiff(hunks: [Hunk(oldStart: 0, newStart: 1, lines: lines.map { .added($0) })], isBinary: false)
    }
}
