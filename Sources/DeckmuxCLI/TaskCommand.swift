import DeckmuxTasks
import Foundation

/// `deckmux task …`: the Hoje board from the shell, mainly for Claude Code,
/// which only uses it when the user asks.
enum TaskCommand {
    static let help = """
    deckmux task: quadro de tarefas da tela Hoje do Deckmux.
    Só crie ou altere tarefas quando o usuário pedir explicitamente.

      deckmux task add <título> [-d <descrição>] [-w <workspace>] [--repo <pasta>]
                       [--link <url>]... [--column todo|doing|done]
      deckmux task list [--all] [-w <workspace>] [--json]
      deckmux task show <id> [--json]
      deckmux task move <id> todo|doing|done
      deckmux task done <id>
      deckmux task edit <id> [--title <título>] [-d <descrição>] [-w <workspace>|--no-workspace]
                        [--repo <pasta>|--no-repo] [--link <url>]... [--remove-link <url>]...
      deckmux task rm <id>

    O workspace (slug) vem da pasta atual quando não é informado. --repo . liga a
    tarefa ao repo da pasta atual. Links do ClickUp e do Zoho são reconhecidos
    pelo endereço. Tarefas feitas saem do quadro depois de 7 dias (--all mostra).
    """

    static func run(_ args: [String]) -> Int32 {
        guard let command = args.first, !["-h", "--help", "help"].contains(command) else {
            print(help)
            return 0
        }
        do {
            let options = try Options(Array(args.dropFirst()))
            switch command {
            case "add": try add(options)
            case "list", "ls": try list(options)
            case "show": try show(options)
            case "move", "mv": try move(options)
            case "done": try done(options)
            case "edit": try edit(options)
            case "rm", "remove", "delete": try remove(options)
            default: throw Failure("comando desconhecido: \(command). Veja deckmux task --help.")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("deckmux task: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    // MARK: Commands

    private static func add(_ options: Options) throws {
        let title = (options.value("--title") ?? options.positional.joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw Failure("falta o título. Ex.: deckmux task add \"Revisar PR\"") }
        let column = try options.value("--column").map(parseColumn) ?? .todo
        let repo = try options.value("--repo").map(resolveRepo)
        let workspace = options.value("-w", "--workspace")
            ?? workspaceSlug(containing: repo ?? FileManager.default.currentDirectoryPath)
        let task = try TaskStore.add(
            title: title, details: options.value("-d", "--description").map(unescape), column: column,
            workspace: workspace, repo: repo, links: try options.values("--link").map(validLink),
            createdBy: ProcessInfo.processInfo.environment["CLAUDECODE"] == "1" ? .claude : .user
        )
        print("Criada #\(task.id): \(task.title) (\(task.column.title)\(task.workspace.map { ", \($0)" } ?? ""))")
    }

    private static func list(_ options: Options) throws {
        let workspace = options.value("-w", "--workspace")
        let tasks = try TaskStore.load()
            .filter { options.flag("--all") || !$0.isArchived() }
            .filter { workspace == nil || $0.workspace == workspace }
            .sorted { ($0.column.rank, $0.order) < ($1.column.rank, $1.order) }
        if options.flag("--json") { return try printJSON(tasks) }
        if tasks.isEmpty { return print("Nenhuma tarefa.") }
        for column in TaskItem.Column.allCases {
            let inColumn = tasks.filter { $0.column == column }
            guard !inColumn.isEmpty else { continue }
            print("\(column.title):")
            for task in inColumn { print("  " + summary(task)) }
        }
    }

    private static func show(_ options: Options) throws {
        let task = try find(options.id())
        if options.flag("--json") { return try printJSON(task) }
        print(summary(task))
        if let details = task.details, !details.isEmpty { print("\n" + details + "\n") }
        if let repo = task.repo { print("Repo: \(repo)") }
        for link in task.links { print("\(TaskLinkKind(link).name): \(link)") }
        print("Criada por \(task.createdBy == .claude ? "Claude" : "você") em \(format(task.createdAt))")
        if let doneAt = task.doneAt { print("Feita em \(format(doneAt))") }
    }

    private static func move(_ options: Options) throws {
        let id = try options.id()
        guard options.positional.count >= 2 else { throw Failure("falta a coluna: todo, doing ou done.") }
        let column = try parseColumn(options.positional[1])
        try TaskStore.move(id, to: column)
        print("#\(id) → \(column.title)")
    }

    private static func done(_ options: Options) throws {
        let id = try options.id()
        try TaskStore.move(id, to: .done)
        print("#\(id) → Feito")
    }

    private static func edit(_ options: Options) throws {
        let id = try options.id()
        let title = options.value("--title")
        let details = options.value("-d", "--description").map(unescape)
        let workspace = options.value("-w", "--workspace")
        let repo = try options.value("--repo").map(resolveRepo)
        let added = try options.values("--link").map(validLink)
        let removed = options.values("--remove-link")
        let task = try TaskStore.update(id) { task in
            if let title, !title.isEmpty { task.title = title }
            if let details { task.details = details.isEmpty ? nil : details }
            if let workspace { task.workspace = workspace }
            if options.flag("--no-workspace") { task.workspace = nil }
            if let repo { task.repo = repo }
            if options.flag("--no-repo") { task.repo = nil }
            task.links.removeAll { removed.contains($0) }
            task.links += added.filter { !task.links.contains($0) }
        }
        print("Atualizada " + summary(task))
    }

    private static func remove(_ options: Options) throws {
        let id = try options.id()
        let task = try find(id)
        try TaskStore.remove(id)
        print("Apagada #\(id): \(task.title)")
    }

    // MARK: Helpers

    private static func find(_ id: Int) throws -> TaskItem {
        guard let task = try TaskStore.load().first(where: { $0.id == id }) else { throw TaskStore.StoreError.notFound(id) }
        return task
    }

    private static func summary(_ task: TaskItem) -> String {
        var parts = ["#\(task.id) \(task.title)"]
        if let workspace = task.workspace { parts.append("[\(workspace)]") }
        let kinds = task.links.map { TaskLinkKind($0).name } + (task.repo.map { ["repo \(URL(fileURLWithPath: $0).lastPathComponent)"] } ?? [])
        if !kinds.isEmpty { parts.append("(" + kinds.joined(separator: ", ") + ")") }
        if task.createdBy == .claude { parts.append("✳") }
        return parts.joined(separator: " ")
    }

    private static func parseColumn(_ text: String) throws -> TaskItem.Column {
        guard let column = TaskItem.Column(argument: text) else { throw Failure("coluna inválida: \(text). Use todo, doing ou done.") }
        return column
    }

    private static func resolveRepo(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath,
                      relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure("a pasta do repo não existe: \(path)")
        }
        return url.path
    }

    private static func validLink(_ text: String) throws -> String {
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
            throw Failure("link inválido: \(text)")
        }
        return text
    }

    /// Lets a one-line argument carry paragraphs: "\n" becomes a line break.
    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n")
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter.string(from: date)
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Flags with values, bare flags and positional words.
    struct Options {
        private(set) var positional: [String] = []
        private var pairs: [(String, String)] = []
        private var flags: Set<String> = []

        static let bare: Set<String> = ["--all", "--json", "--no-repo", "--no-workspace"]

        init(_ args: [String]) throws {
            var index = 0
            while index < args.count {
                let arg = args[index]
                if Self.bare.contains(arg) {
                    flags.insert(arg)
                } else if arg.hasPrefix("-") && arg.count > 1 && Int(arg) == nil {
                    guard index + 1 < args.count else { throw Failure("\(arg) precisa de um valor.") }
                    pairs.append((arg, args[index + 1]))
                    index += 1
                } else {
                    positional.append(arg)
                }
                index += 1
            }
        }

        func value(_ names: String...) -> String? { pairs.last { names.contains($0.0) }?.1 }
        func values(_ name: String) -> [String] { pairs.filter { $0.0 == name }.map(\.1) }
        func flag(_ name: String) -> Bool { flags.contains(name) }

        func id() throws -> Int {
            guard let first = positional.first, let id = Int(first.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) else {
                throw Failure("falta o número da tarefa. Ex.: deckmux task show 12")
            }
            return id
        }
    }
}

private extension TaskItem.Column {
    var rank: Int { TaskItem.Column.allCases.firstIndex(of: self) ?? 0 }
}
