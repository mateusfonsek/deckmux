import CoreServices
import DeckmuxCode
import Foundation

/// Watches a code tab's root, recursively and file by file, and reports the
/// paths that changed (canonical, absolute). The `.git` folder is inside the
/// root, so staging and commits are seen too; `WatchFilter` drops the noise
/// (lock files, objects, logs). Lives only while the tab can be seen.
///
/// In a linked worktree or a submodule `.git` is a file and the index, HEAD
/// and refs live elsewhere (`<main>/.git/worktrees/<name>`, the common dir,
/// `<super>/.git/modules/<name>`). Those folders are given as `gitDirs`
/// (most specific first) and their events are reported as if they were
/// under `<root>/.git/`, so the same filter and the same "git changed"
/// handling apply.
final class RepoWatcher {
    /// The root as FSEvents spells it (`/private/var/...`, symlinks resolved).
    let rootPath: String
    private let gitDirs: [String]
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void

    init?(root: URL, gitDirs: [String] = [], onChange: @escaping ([String]) -> Void) {
        rootPath = TerminalLayout.canonicalPath(root.path)
        self.gitDirs = gitDirs.map(TerminalLayout.canonicalPath)
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watcher.handle(Array(array.prefix(count)))
        }
        // WatchRoot also reports the root itself being moved or deleted.
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, ([rootPath] + self.gitDirs) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func handle(_ paths: [String]) {
        let relevant = paths.map(spelledUnderRoot).filter { WatchFilter.isRelevant($0, root: rootPath) }
        if !relevant.isEmpty { onChange(relevant) }
    }

    /// `<gitDir>/index` → `<root>/.git/index`; paths under the root as they are.
    private func spelledUnderRoot(_ path: String) -> String {
        if path == rootPath || path.hasPrefix(rootPath + "/") { return path }
        for dir in gitDirs where path == dir || path.hasPrefix(dir + "/") {
            return rootPath + "/.git" + path.dropFirst(dir.count)
        }
        return path
    }
}
