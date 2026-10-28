import AppKit
import DeckmuxMonitor

/// Watches each conversation's `subagents/` folder. The folder
/// may not exist yet (no subagent spawned so far), so the watcher sits on the
/// deepest existing ancestor and moves down as folders appear. Reads happen
/// off the main thread, 500 ms after the last event.
@MainActor
final class SubagentWatcher {
    private struct Watch {
        var folder: URL           // the subagents folder we want
        var watchedRoot: URL      // where the FSEvents stream currently sits
        var watcher: DirectoryWatcher?
        var pending: DispatchWorkItem?
        var last: [SubagentInfo] = []
    }

    private let claudeHome: URL
    private var watches: [UUID: Watch] = [:]
    private let queue = DispatchQueue(label: "dev.fonsek.deckmux.subagents", qos: .utility)

    var onChange: ((UUID, [SubagentInfo]) -> Void)?

    init(claudeHome: URL = ConfigPaths.home.appendingPathComponent(".claude", isDirectory: true)) {
        self.claudeHome = claudeHome
    }

    /// Watches each session's conversation folder; stops watching the ones no longer listed.
    func watch(_ sessions: [(terminal: UUID, cwd: String, sessionID: String)]) {
        let wanted = Set(sessions.map(\.terminal))
        for id in watches.keys where !wanted.contains(id) {
            watches[id]?.pending?.cancel()
            watches[id] = nil
        }
        for session in sessions {
            let folder = TranscriptPaths.subagentsFolder(claudeHome: claudeHome, cwd: session.cwd, sessionID: session.sessionID)
            if let existing = watches[session.terminal], existing.folder == folder { continue }
            watches[session.terminal] = Watch(folder: folder, watchedRoot: folder)
            attach(session.terminal)
            schedule(session.terminal)
        }
    }

    func stop() {
        for watch in watches.values { watch.pending?.cancel() }
        watches = [:]
    }

    /// Streams from the deepest ancestor of the folder that exists, accepting
    /// only events on the folder's own path (or the folders on the way to it).
    private func attach(_ id: UUID) {
        guard var watch = watches[id] else { return }
        // Up to the home folder: `~/.claude` itself may not exist yet.
        var root = watch.folder
        let floor = claudeHome.deletingLastPathComponent().pathComponents.count
        while !FileManager.default.fileExists(atPath: root.path), root.pathComponents.count > floor {
            root.deleteLastPathComponent()
        }
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let relative = String(watch.folder.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        watch.watchedRoot = root
        watch.watcher = DirectoryWatcher(root: root, matching: { path in
            relative.isEmpty || path == relative || path.hasPrefix(relative + "/") || relative.hasPrefix(path + "/")
        }) { [weak self] in
            MainActor.assumeIsolated { self?.changed(id) }
        }
        watches[id] = watch
    }

    private func changed(_ id: UUID) {
        guard let watch = watches[id] else { return }
        // A deeper folder exists now: move the stream down to it.
        if watch.watchedRoot != watch.folder, FileManager.default.fileExists(atPath: watch.folder.path) {
            attach(id)
        }
        schedule(id)
    }

    private func schedule(_ id: UUID) {
        guard var watch = watches[id] else { return }
        watch.pending?.cancel()
        let folder = watch.folder
        let work = DispatchWorkItem { [weak self] in
            let agents = SubagentReader.read(folder: folder, now: Date())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, var current = self.watches[id], current.folder == folder, current.last != agents else { return }
                    current.last = agents
                    self.watches[id] = current
                    self.onChange?(id, agents)
                }
            }
        }
        watch.pending = work
        watches[id] = watch
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
