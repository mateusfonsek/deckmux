import CoreServices
import Foundation

/// Watches a root folder for changes that can add, remove or edit a workspace:
/// a direct child folder appearing or disappearing, or a `<child>/.workspace.json`
/// changing. Everything else under the root (repos being edited, builds) is ignored.
/// With `matching`, any path the predicate accepts (relative to the root) counts
/// instead (the Janelinha watches a conversation's folders this way).
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let rootPath: String
    private let onChange: () -> Void
    private let matching: ((String) -> Bool)?

    init?(root: URL, matching: ((String) -> Bool)? = nil, onChange: @escaping () -> Void) {
        rootPath = Self.canonicalPath(root.path)
        self.onChange = onChange
        self.matching = matching

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watcher.handle(Array(array.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [rootPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags
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

    /// FSEvents reports canonical paths (`/private/tmp/...`); Foundation's
    /// `resolvingSymlinksInPath` would strip `/private` and never match them.
    private static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func handle(_ paths: [String]) {
        let relevant = paths.contains { path in
            guard path.hasPrefix(rootPath + "/") else { return path == rootPath }
            let relative = String(path.dropFirst(rootPath.count + 1))
            if let matching { return matching(relative) }
            let parts = relative.split(separator: "/")
            return parts.count == 1 || (parts.count == 2 && parts[1] == WorkspaceManifest.fileName)
        }
        if relevant { onChange() }
    }
}
