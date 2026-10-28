import Foundation

/// Which list of the code tab a change belongs to.
public enum ChangeGroup: String, Codable, Sendable { case staged, unstaged }

/// Kind of change, with the letter shown in the UI.
public enum ChangeKind: String, Sendable {
    case modified = "M", added = "A", deleted = "D", renamed = "R", copied = "C"
    case typeChanged = "T", untracked = "U", conflict = "!"
}

/// One entry of `git status`. Paths are relative to the repository root, as git reports them.
public struct FileChange: Equatable, Hashable, Sendable {
    public var path: String
    public var originalPath: String?
    public var kind: ChangeKind
    public var group: ChangeGroup

    public init(path: String, originalPath: String?, kind: ChangeKind, group: ChangeGroup) {
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
        self.group = group
    }
}

/// Parsed output of `git status -z --porcelain=v1 -uall --find-renames`.
public struct GitStatus: Equatable, Sendable {
    public var staged: [FileChange]
    public var unstaged: [FileChange]
    /// True when the output had more entries than the limit and the rest was dropped.
    public var truncated: Bool

    public static let empty = GitStatus(staged: [], unstaged: [], truncated: false)

    public init(staged: [FileChange], unstaged: [FileChange], truncated: Bool) {
        self.staged = staged
        self.unstaged = unstaged
        self.truncated = truncated
    }

    private static let conflictPairs: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]

    private static func kind(_ c: Character) -> ChangeKind? {
        switch c {
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        default: return nil
        }
    }

    /// Records are `XY path\0`; renames and copies are followed by a record with the old path.
    public static func parse(_ output: Data, limit: Int = 10_000) -> GitStatus {
        var result = GitStatus.empty
        var count = 0
        let records = output.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        var i = 0

        func add(_ change: FileChange) -> Bool {
            if count >= limit { result.truncated = true; return false }
            if change.group == .staged { result.staged.append(change) } else { result.unstaged.append(change) }
            count += 1
            return true
        }

        while i < records.count {
            let record = records[i]
            i += 1
            guard record.count >= 4 else { continue }
            let chars = Array(record)
            let x = chars[0], y = chars[1]
            let path = String(chars[3...])
            var original: String?
            if "RC".contains(x) || "RC".contains(y), i < records.count {
                original = records[i]
                i += 1
            }
            let xy = String([x, y])
            if xy == "!!" { continue }
            if xy == "??" {
                if !add(.init(path: path, originalPath: nil, kind: .untracked, group: .unstaged)) { break }
                continue
            }
            if conflictPairs.contains(xy) {
                if !add(.init(path: path, originalPath: nil, kind: .conflict, group: .unstaged)) { break }
                continue
            }
            if "MADRCT".contains(x), let k = kind(x) {
                if !add(.init(path: path, originalPath: original, kind: k, group: .staged)) { break }
            }
            if "MDTA".contains(y), let k = kind(y) {
                if !add(.init(path: path, originalPath: nil, kind: k, group: .unstaged)) { break }
            }
        }
        return result
    }
}
