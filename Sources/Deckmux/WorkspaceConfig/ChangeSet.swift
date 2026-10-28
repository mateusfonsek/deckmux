import Foundation
import OSLog

/// One file a workspace operation changes. The change is a function of the
/// file's text, not fixed text, so it is applied again to whatever is on disk
/// at the moment of writing: Claude Code rewrites `~/.claude.json` often, and
/// a stale copy would undo its changes.
struct FileChange: Identifiable {
    enum Operation {
        /// New text from the current one (nil when the file does not exist).
        /// Returning nil deletes the file.
        case edit((String?) throws -> String?)
        /// Copies a file the user picked (a secret: never shown in the review).
        case copy(from: URL)
        /// Deletes a folder and everything in it.
        case removeFolder
    }

    let id = UUID()
    let url: URL
    /// Outside the workspace folder (Claude Code's global files, credentials).
    let isGlobal: Bool
    /// One line saying what changes, shown above the diff.
    let summary: String
    let operation: Operation
    /// Permissions for the written file (credentials are 600).
    var permissions: Int?

    /// Filled by `ChangeSet.prepare()`.
    fileprivate(set) var before: String?
    fileprivate(set) var after: String?
    fileprivate(set) var folderContents: [String] = []

    var isSecret: Bool { if case .copy = operation { true } else { false } }
    var isFolderRemoval: Bool { if case .removeFolder = operation { true } else { false } }
    var deletesFile: Bool { before != nil && after == nil && !isFolderRemoval && !isSecret }
    var createsFile: Bool { before == nil && after != nil }
}

/// Everything one operation will write, prepared for review and applied with
/// a backup.
struct ChangeSet {
    private static let logger = Logger(subsystem: "dev.fonsek.deckmux", category: "workspace-config")

    let title: String
    private(set) var changes: [FileChange]
    /// Problems found while preparing (a file that is not valid JSON, …).
    private(set) var problems: [String] = []

    init(title: String, changes: [FileChange]) {
        self.title = title
        self.changes = changes
    }

    var isEmpty: Bool { changes.isEmpty }

    /// Computes each file's text before and after, and drops changes that
    /// would not change anything.
    mutating func prepare() {
        let fm = FileManager.default
        var prepared: [FileChange] = []
        problems = []
        for var change in changes {
            let current = try? String(contentsOf: change.url, encoding: .utf8)
            switch change.operation {
            case .edit(let transform):
                do {
                    change.before = current
                    change.after = try transform(current)
                } catch {
                    problems.append("\(ConfigPaths.display(change.url)): \(error.localizedDescription)")
                    continue
                }
                guard change.before != change.after else { continue }
            case .copy(let source):
                guard let data = try? Data(contentsOf: source) else {
                    problems.append("Não foi possível ler \(source.path)")
                    continue
                }
                if let existing = try? Data(contentsOf: change.url), existing == data { continue }
                change.before = current == nil ? nil : "(oculto)"
                change.after = "(oculto)"
            case .removeFolder:
                guard fm.fileExists(atPath: change.url.path) else { continue }
                let items = (fm.enumerator(atPath: change.url.path)?.allObjects as? [String]) ?? []
                change.folderContents = items.sorted()
            }
            prepared.append(change)
        }
        changes = prepared
    }

    /// Copies every file it will touch to a backup folder, then writes each
    /// change atomically and reads it back. Stops at the first failure and
    /// says which files were already written.
    func apply() throws {
        let fm = FileManager.default
        let backup = try backupFolder()
        for change in changes where fm.fileExists(atPath: change.url.path) {
            let target = backup.appendingPathComponent(String(change.url.path.dropFirst()))
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: change.url, to: target)
        }

        var written: [String] = []
        for change in changes {
            do {
                try write(change)
                written.append(ConfigPaths.display(change.url))
            } catch {
                let done = written.isEmpty ? "" : " Já gravados: \(written.joined(separator: ", "))."
                throw ApplyError(message: "Falhou em \(ConfigPaths.display(change.url)): \(error.localizedDescription).\(done) Backup em \(backup.path).")
            }
        }
        Self.logger.info("Applied \(self.title, privacy: .public); backup in \(backup.path, privacy: .public)")
    }

    private func write(_ change: FileChange) throws {
        let fm = FileManager.default
        switch change.operation {
        case .edit(let transform):
            // Re-read now: the file may have changed since the review.
            let current = try? String(contentsOf: change.url, encoding: .utf8)
            guard let text = try transform(current) else {
                if fm.fileExists(atPath: change.url.path) { try fm.removeItem(at: change.url) }
                return
            }
            try Self.atomicWrite(Data(text.utf8), to: change.url, permissions: change.permissions)
            let check = try String(contentsOf: change.url, encoding: .utf8)
            guard check == text else { throw ApplyError(message: "o arquivo mudou durante a gravação") }
        case .copy(let source):
            try Self.atomicWrite(try Data(contentsOf: source), to: change.url, permissions: change.permissions ?? 0o600)
        case .removeFolder:
            if fm.fileExists(atPath: change.url.path) { try fm.removeItem(at: change.url) }
        }
    }

    /// Writes to a temporary file next to the target and renames it over.
    static func atomicWrite(_ data: Data, to url: URL, permissions: Int?) throws {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        // Folders created for a secret are private too (as workspace-mcp makes them).
        let folderMode: [FileAttributeKey: Any]? = permissions == 0o600 ? [.posixPermissions: 0o700] : nil
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: folderMode)
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).deckmux-\(UUID().uuidString.prefix(8))")
        try data.write(to: temp)
        let mode = permissions ?? ((try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int) ?? 0o644
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)
        if rename(temp.path, url.path) != 0 {
            let code = errno
            try? fm.removeItem(at: temp)
            throw ApplyError(message: String(cString: strerror(code)))
        }
    }

    private static var backupsRoot: URL { SessionStore.directory.appendingPathComponent("backups", isDirectory: true) }

    private func backupFolder() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = Self.backupsRoot
            .appendingPathComponent("\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Self.pruneBackups()
        return folder
    }

    /// Backups older than 30 days are deleted.
    private static func pruneBackups() {
        let fm = FileManager.default
        let limit = Date().addingTimeInterval(-30 * 24 * 3600)
        let folders = (try? fm.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            if created < limit { try? fm.removeItem(at: folder) }
        }
    }
}

struct ApplyError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
