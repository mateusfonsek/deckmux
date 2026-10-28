import Foundation

/// Per-path change kinds for coloring the file tree. Keys are normalized to NFC
/// (git reports NFC, the file system may report NFD) and folders are computed once.
public struct Decorations: Sendable {
    private var files: [String: ChangeKind] = [:]
    private var folders: [String: ChangeKind] = [:]

    // Highest priority first.
    private static let folderPriority: [ChangeKind] = [.conflict, .modified, .typeChanged, .added, .renamed, .copied, .untracked]

    private static func rank(_ k: ChangeKind) -> Int {
        folderPriority.firstIndex(of: k) ?? Int.max
    }

    private static func normalize(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }

    public init(_ status: GitStatus) {
        // The worktree kind wins over the index kind, so unstaged is applied last.
        for change in status.staged + status.unstaged {
            let path = Self.normalize(change.path)
            files[path] = change.kind
            guard change.kind != .deleted else { continue }
            var parts = path.split(separator: "/", omittingEmptySubsequences: true).dropLast()
            while !parts.isEmpty {
                let folder = parts.joined(separator: "/")
                if let current = folders[folder], Self.rank(current) <= Self.rank(change.kind) {
                    // Already at least as important; ancestors have it too.
                    parts = parts.dropLast()
                    continue
                }
                folders[folder] = change.kind
                parts = parts.dropLast()
            }
        }
    }

    public func kind(ofFile path: String) -> ChangeKind? { files[Self.normalize(path)] }
    public func kind(ofFolder path: String) -> ChangeKind? { folders[Self.normalize(path)] }
}
