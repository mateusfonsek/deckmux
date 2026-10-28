import Darwin
import Foundation

/// A task on the Hoje board. Created by the user in the app or by
/// Claude through `deckmux task`, only when the user asks.
public struct TaskItem: Codable, Identifiable, Equatable, Sendable {
    public enum Column: String, Codable, CaseIterable, Sendable {
        case todo, doing, done

        public var title: String {
            switch self {
            case .todo: "A fazer"
            case .doing: "Fazendo"
            case .done: "Feito"
            }
        }

        /// Accepts the English names and the Portuguese titles ("a fazer", "fazendo", "feito").
        public init?(argument: String) {
            let key = argument.lowercased().folding(options: .diacriticInsensitive, locale: nil)
                .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
            switch key {
            case "todo", "afazer": self = .todo
            case "doing", "fazendo": self = .doing
            case "done", "feito", "feita": self = .done
            default: return nil
            }
        }
    }

    public enum Creator: String, Codable, Sendable { case user, claude }

    /// Short and sequential, so it is easy to say: "move a #12 para feito".
    public let id: Int
    public var title: String
    public var details: String?
    public var column: Column
    /// Workspace slug.
    public var workspace: String?
    /// A local repo folder.
    public var repo: String?
    public var links: [String]
    public let createdBy: Creator
    public let createdAt: Date
    public var updatedAt: Date
    public var doneAt: Date?
    /// Position inside the column; lower comes first.
    public var order: Double

    /// Done tasks leave the board 7 days after they were done; they stay in the file.
    public static let archiveAfter: TimeInterval = 7 * 86_400

    public func isArchived(now: Date = Date()) -> Bool {
        column == .done && (doneAt.map { now.timeIntervalSince($0) > Self.archiveAfter } ?? false)
    }

    public mutating func move(to newColumn: Column, now: Date = Date()) {
        guard column != newColumn else { return }
        column = newColumn
        doneAt = newColumn == .done ? now : nil
        updatedAt = now
    }
}

/// What kind of page a link opens, from its address.
public enum TaskLinkKind: Sendable {
    case clickup, zoho, github, other

    public init(_ link: String) {
        let host = URL(string: link)?.host?.lowercased() ?? ""
        if host == "clickup.com" || host.hasSuffix(".clickup.com") { self = .clickup }
        else if host.contains("zoho.") { self = .zoho }
        else if host == "github.com" || host.hasSuffix(".github.com") { self = .github }
        else { self = .other }
    }

    public var openTitle: String {
        switch self {
        case .clickup: "Abrir no ClickUp"
        case .zoho: "Abrir no Zoho"
        case .github: "Abrir no GitHub"
        case .other: "Abrir link"
        }
    }

    public var name: String {
        switch self {
        case .clickup: "ClickUp"
        case .zoho: "Zoho"
        case .github: "GitHub"
        case .other: "Link"
        }
    }
}

/// `tasks.json` in Deckmux's support folder, shared by the app and the CLI.
/// Every change runs under an exclusive lock and re-reads the file first, so
/// the two never overwrite each other.
public enum TaskStore {
    struct File: Codable {
        var version = 1
        var nextID = 1
        var tasks: [TaskItem] = []
    }

    public enum StoreError: LocalizedError {
        case unreadable(String)
        case notFound(Int)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let reason): "Não consegui ler tasks.json: \(reason)"
            case .notFound(let id): "Não existe a tarefa #\(id)."
            }
        }
    }

    /// Same folder as the session: `DECKMUX_SUPPORT_DIR`, or
    /// `~/Library/Application Support/Deckmux`.
    public static var url: URL {
        let folder: URL
        if let override = ProcessInfo.processInfo.environment["DECKMUX_SUPPORT_DIR"], !override.isEmpty {
            folder = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Deckmux", isDirectory: true)
        }
        return folder.appendingPathComponent("tasks.json")
    }

    public static func load() throws -> [TaskItem] {
        try read().tasks
    }

    @discardableResult
    public static func add(
        title: String, details: String? = nil, column: TaskItem.Column = .todo,
        workspace: String? = nil, repo: String? = nil, links: [String] = [],
        createdBy: TaskItem.Creator, now: Date = Date()
    ) throws -> TaskItem {
        try change { file in
            let order = (file.tasks.filter { $0.column == column }.map(\.order).max() ?? 0) + 1
            let task = TaskItem(
                id: file.nextID, title: title, details: details, column: column,
                workspace: workspace, repo: repo, links: links, createdBy: createdBy,
                createdAt: now, updatedAt: now, doneAt: column == .done ? now : nil, order: order
            )
            file.nextID += 1
            file.tasks.append(task)
            return task
        }
    }

    /// Applies `edit` to task `id` and saves it.
    @discardableResult
    public static func update(_ id: Int, now: Date = Date(), _ edit: (inout TaskItem) -> Void) throws -> TaskItem {
        try change { file in
            guard let index = file.tasks.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound(id) }
            edit(&file.tasks[index])
            file.tasks[index].updatedAt = now
            return file.tasks[index]
        }
    }

    /// Moves task `id` to `column`, before the task `before` (or at the end).
    /// With `keepingPosition`, a task already in `column` stays where it is.
    public static func move(_ id: Int, to column: TaskItem.Column, before: Int? = nil,
                            keepingPosition: Bool = false, now: Date = Date()) throws {
        try change { file in
            guard let index = file.tasks.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound(id) }
            if keepingPosition && file.tasks[index].column == column { return }
            file.tasks[index].move(to: column, now: now)
            var others = file.tasks.indices
                .filter { file.tasks[$0].column == column && $0 != index }
                .sorted { file.tasks[$0].order < file.tasks[$1].order }
            let position = before.flatMap { target in others.firstIndex { file.tasks[$0].id == target } } ?? others.count
            others.insert(index, at: position)
            for (rank, taskIndex) in others.enumerated() { file.tasks[taskIndex].order = Double(rank + 1) }
            file.tasks[index].updatedAt = now
        }
    }

    public static func remove(_ id: Int) throws {
        try change { file in
            guard let index = file.tasks.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound(id) }
            file.tasks.remove(at: index)
        }
    }

    // MARK: File

    private static func read() throws -> File {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return File() }
        do {
            return try decoder.decode(File.self, from: data)
        } catch {
            throw StoreError.unreadable(error.localizedDescription)
        }
    }

    /// Runs `body` on the current file under an exclusive lock and saves the
    /// result atomically.
    private static func change<T>(_ body: (inout File) throws -> T) throws -> T {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lock = open(folder.appendingPathComponent("tasks.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw StoreError.unreadable("sem trava") }
        defer { close(lock) }
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN) }

        var file = try read()
        let result = try body(&file)
        let data = try encoder.encode(file)
        try data.write(to: url, options: .atomic)
        return result
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// The workspace a folder belongs to: the slug of the nearest `.workspace.json`
/// above it, as the status line finds it.
public func workspaceSlug(containing path: String) -> String? {
    var url = URL(fileURLWithPath: path).standardizedFileURL
    while true {
        let manifest = url.appendingPathComponent(".workspace.json")
        if let data = try? Data(contentsOf: manifest),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let slug = json["slug"] as? String {
            return slug
        }
        let parent = url.deletingLastPathComponent()
        if parent.path == url.path { return nil }
        url = parent
    }
}
