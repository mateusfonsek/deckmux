import Foundation
import GhosttyKit
import OSLog

/// Reads and writes the session under `~/Library/Application Support/Deckmux`:
/// `session.json` (the last saved state), `session-previous.json` (the state
/// this launch started from, for "Reabrir sessão anterior") and one scrollback
/// file per terminal in `scrollback/`.
enum SessionStore {
    private static let logger = Logger(subsystem: "dev.fonsek.deckmux", category: "session")

    /// Same budget as cmux: enough history to pick up where you left off,
    /// small enough to replay instantly.
    static let scrollbackMaxRows = 4_000
    static let scrollbackMaxBytes = 400_000

    /// `DECKMUX_SUPPORT_DIR` moves the session, the hook socket and the
    /// backups elsewhere, so a test instance never touches the real ones.
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["DECKMUX_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Deckmux", isDirectory: true)
    }

    private static var currentURL: URL { directory.appendingPathComponent("session.json") }
    private static var previousURL: URL { directory.appendingPathComponent("session-previous.json") }
    private static var scrollbackDirectory: URL { directory.appendingPathComponent("scrollback", isDirectory: true) }

    // MARK: Snapshot

    /// The saved session, kept as the previous one so it can be reopened
    /// later even after this launch overwrites `session.json`.
    static func loadForLaunch() -> SessionSnapshot? {
        guard let snapshot = load(currentURL) else { return nil }
        let fm = FileManager.default
        try? fm.removeItem(at: previousURL)
        try? fm.copyItem(at: currentURL, to: previousURL)
        return snapshot
    }

    static func loadPrevious() -> SessionSnapshot? { load(previousURL) }

    private static func load(_ url: URL) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: data)
            guard snapshot.version == SessionSnapshot.currentVersion else { return nil }
            return snapshot
        } catch {
            logger.error("Ignoring unreadable session \(url.path, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    /// Writes `snapshot` if it differs from the last one written.
    static func save(_ snapshot: SessionSnapshot) {
        guard snapshot != lastSaved else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: currentURL, options: .atomic)
            lastSaved = snapshot
        } catch {
            logger.error("Could not save the session: \(error, privacy: .public)")
        }
    }

    private static var lastSaved: SessionSnapshot?

    // MARK: Scrollback

    /// The content last written for each terminal, to skip unchanged ones.
    @MainActor private static var savedScrollbackHashes: [UUID: Int] = [:]
    /// Terminals whose file exists (written by this launch, or found on disk).
    @MainActor private static var scrollbackOnDisk: Set<UUID> = []
    /// Cleaning and writing happen here, in order, off the main thread.
    private static let scrollbackQueue = DispatchQueue(label: "dev.fonsek.deckmux.scrollback", qos: .utility)

    /// Saves the newest rows of `surface`, with their colors and styles, as VT
    /// text. Only possible with the cmux fork of libghostty.
    ///
    /// Only the read from libghostty runs on the main thread (the surface is
    /// owned there). Most terminals have not changed since the last save,
    /// so the raw bytes are hashed first and an unchanged terminal costs
    /// nothing more; cleaning and writing the others happens on `scrollbackQueue`.
    /// Rewriting every one every 32 s was gigabytes of disk writes a day.
    @MainActor static func saveScrollback(of surface: ghostty_surface_t, terminal id: UUID) {
        var text = ghostty_text_s()
        guard ghostty_surface_read_screen_tail_vt(surface, UInt(scrollbackMaxRows), UInt(scrollbackMaxBytes), &text) else { return }
        defer { ghostty_surface_free_text(surface, &text) }
        let url = scrollbackURL(id)
        guard let pointer = text.text, text.text_len > 0 else {
            savedScrollbackHashes[id] = nil
            scrollbackOnDisk.remove(id)
            scrollbackQueue.async { try? FileManager.default.removeItem(at: url) }
            return
        }
        var hasher = Hasher()
        hasher.combine(bytes: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)))
        let hash = hasher.finalize()
        if savedScrollbackHashes[id] == hash, scrollbackOnDisk.contains(id) || FileManager.default.fileExists(atPath: url.path) {
            scrollbackOnDisk.insert(id)
            return
        }
        savedScrollbackHashes[id] = hash
        scrollbackOnDisk.insert(id)
        let raw = Data(bytes: pointer, count: Int(text.text_len))
        scrollbackQueue.async {
            do {
                try FileManager.default.createDirectory(at: scrollbackDirectory, withIntermediateDirectories: true)
                try withoutDynamicColors(raw).write(to: url, options: .atomic)
            } catch {
                logger.error("Could not save scrollback: \(error, privacy: .public)")
            }
        }
    }

    /// Ghostty starts the tail by setting the terminal's default colors
    /// (OSC 10, 11 and 12). Replaying them would pin the colors of the theme in
    /// use when it was saved, so they are dropped.
    private static func withoutDynamicColors(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let cleaned = text.replacingOccurrences(
            of: "\u{1B}\\]1[0-2];[^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)",
            with: "",
            options: .regularExpression
        )
        return Data(cleaned.utf8)
    }

    /// A copy of the saved scrollback of terminal `id` for its new shell to
    /// print once and delete (`DECKMUX_RESTORE_SCROLLBACK_FILE`).
    static func scrollbackReplayFile(for id: UUID) -> String? {
        let source = scrollbackURL(id)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return nil }
        let replayDirectory = fm.temporaryDirectory.appendingPathComponent("deckmux-restore", isDirectory: true)
        let target = replayDirectory.appendingPathComponent("\(UUID().uuidString).vt")
        do {
            try fm.createDirectory(at: replayDirectory, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
            return target.path
        } catch {
            logger.error("Could not prepare scrollback replay: \(error, privacy: .public)")
            return nil
        }
    }

    /// Deletes scrollback files no longer referenced by the current or the
    /// previous session. Runs after the saves queued before it.
    static func pruneScrollback(keeping snapshot: SessionSnapshot) {
        scrollbackQueue.async {
            let fm = FileManager.default
            var keep = Set(snapshot.items.flatMap { $0.layout.shells.map(\.id.uuidString) })
            if let previous = loadPrevious() {
                keep.formUnion(previous.items.flatMap { $0.layout.shells.map(\.id.uuidString) })
            }
            guard let files = try? fm.contentsOfDirectory(at: scrollbackDirectory, includingPropertiesForKeys: nil) else { return }
            for file in files where !keep.contains(file.deletingPathExtension().lastPathComponent) {
                try? fm.removeItem(at: file)
            }
        }
    }

    /// Waits for every queued scrollback write (quitting).
    static func flushScrollback() {
        scrollbackQueue.sync {}
    }

    private static func scrollbackURL(_ id: UUID) -> URL {
        scrollbackDirectory.appendingPathComponent("\(id.uuidString).vt")
    }
}

/// User settings for restoring sessions.
enum SessionSettings {
    private static let resumeClaudeKey = "resumeClaudeSessions"

    /// Whether a terminal that was running Claude Code reopens the same
    /// conversation (`claude --resume <id>`). On by default.
    static var resumesClaudeSessions: Bool {
        get { UserDefaults.standard.object(forKey: resumeClaudeKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: resumeClaudeKey) }
    }
}
