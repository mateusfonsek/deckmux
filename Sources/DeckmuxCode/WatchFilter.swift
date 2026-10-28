import Foundation

/// Drops file-system events that cannot change what the code tab shows.
public enum WatchFilter {
    public static func isRelevant(_ path: String, root: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix(".watchman-cookie") { return false }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        if relative == ".git" || relative.hasPrefix(".git/") {
            let inner = relative.dropFirst(".git/".count)
            if name.hasSuffix(".lock") { return false }
            if inner.hasPrefix("objects/") || inner.hasPrefix("logs/") { return false }
        }
        return true
    }
}
