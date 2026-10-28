import AppKit
import DeckmuxTasks
import SwiftUI

/// The tasks of the Hoje board, read from `tasks.json` and
/// reloaded whenever it changes, so tasks Claude creates with `deckmux task`
/// show up at once.
@MainActor
final class TasksModel: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = []
    @Published var error: String?
    @Published var editing: TaskDraft?

    private var watcher: FileWatcher?

    init() {
        try? FileManager.default.createDirectory(at: TaskStore.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        reload()
        watcher = FileWatcher(url: TaskStore.url) { [weak self] in self?.reload() }
    }

    func reload() {
        do {
            let loaded = try TaskStore.load()
            if loaded != tasks { tasks = loaded }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The column's tasks still on the board, in order.
    func tasks(in column: TaskItem.Column, now: Date = Date()) -> [TaskItem] {
        tasks.filter { $0.column == column && !$0.isArchived(now: now) }.sorted { $0.order < $1.order }
    }

    func archivedCount(now: Date = Date()) -> Int { tasks.filter { $0.isArchived(now: now) }.count }

    func newTask(in column: TaskItem.Column = .todo) {
        editing = TaskDraft(column: column)
    }

    func edit(_ task: TaskItem) {
        editing = TaskDraft(task)
    }

    func save(_ draft: TaskDraft) {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = draft.details.trimmingCharacters(in: .whitespacesAndNewlines)
        perform {
            if let id = draft.taskID {
                try TaskStore.update(id) { task in
                    task.title = title
                    task.details = details.isEmpty ? nil : details
                    task.workspace = draft.workspace
                    task.repo = draft.repo
                    task.links = draft.links
                }
                try TaskStore.move(id, to: draft.column, before: nil, keepingPosition: true)
            } else {
                try TaskStore.add(title: title, details: details.isEmpty ? nil : details, column: draft.column,
                                  workspace: draft.workspace, repo: draft.repo, links: draft.links, createdBy: .user)
            }
        }
        editing = nil
    }

    func move(_ id: Int, to column: TaskItem.Column, before: Int? = nil) {
        guard id != before else { return }
        perform { try TaskStore.move(id, to: column, before: before) }
    }

    func delete(_ id: Int) {
        perform { try TaskStore.remove(id) }
        if editing?.taskID == id { editing = nil }
    }

    private func perform(_ change: () throws -> Void) {
        do {
            try change()
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The task being created or edited in the sheet.
struct TaskDraft: Identifiable {
    let id = UUID()
    var taskID: Int?
    var title = ""
    var details = ""
    var column: TaskItem.Column = .todo
    var workspace: String?
    var repo: String?
    var links: [String] = []
    var createdBy: TaskItem.Creator = .user

    init(column: TaskItem.Column) { self.column = column }

    init(_ task: TaskItem) {
        taskID = task.id
        title = task.title
        details = task.details ?? ""
        column = task.column
        workspace = task.workspace
        repo = task.repo
        links = task.links
        createdBy = task.createdBy
    }
}

// MARK: Board

struct TasksBoard: View {
    @ObservedObject var model: TasksModel
    @ObservedObject var deck: Deck
    @StateObject private var drag = BoardDrag()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tarefas").font(Theme.Font.title)
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
                }
                Spacer()
                let archived = model.archivedCount()
                if archived > 0 {
                    Text(archived == 1 ? "1 arquivada" : "\(archived) arquivadas")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .help("Tarefas feitas há mais de 7 dias saem do quadro. `deckmux task list --all` mostra todas.")
                }
                Button { model.newTask() } label: { Label("Nova tarefa", systemImage: "plus") }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            HStack(alignment: .top, spacing: 10) {
                ForEach(TaskItem.Column.allCases, id: \.self) { column in
                    TaskColumn(column: column, model: model, deck: deck, drag: drag)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .coordinateSpace(name: BoardDrag.space)
        .onPreferenceChange(CardFramesKey.self) { frames in MainActor.assumeIsolated { drag.cardFrames = frames } }
        .onPreferenceChange(ColumnFramesKey.self) { frames in MainActor.assumeIsolated { drag.columnFrames = frames } }
        .overlay(alignment: .topLeading) {
            // The dragged card follows the pointer above every column.
            if let id = drag.taskID, let task = model.tasks.first(where: { $0.id == id }) {
                TaskCard(task: task, workspace: deck.workspaces.workspace(slug: task.workspace), model: model, deck: deck, drag: drag, isGhost: true)
                    .frame(width: drag.size.width, height: drag.size.height)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                    .offset(x: drag.location.x - drag.grab.width, y: drag.location.y - drag.grab.height)
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $model.editing) { draft in
            TaskEditor(draft: draft, model: model, deck: deck)
        }
    }
}

private struct TaskColumn: View {
    let column: TaskItem.Column
    @ObservedObject var model: TasksModel
    @ObservedObject var deck: Deck
    @ObservedObject var drag: BoardDrag

    var body: some View {
        let tasks = model.tasks(in: column)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(column.title).font(.system(size: 13, weight: .semibold))
                Text("\(tasks.count)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button { model.newTask(in: column) } label: { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.borderless)
                    .help("Nova tarefa em \(column.title)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(tasks) { task in
                        TaskCard(task: task, workspace: deck.workspaces.workspace(slug: task.workspace), model: model, deck: deck, drag: drag)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: CardFramesKey.self, value: [task.id: geometry.frame(in: .named(BoardDrag.space))])
                            })
                    }
                    if tasks.isEmpty {
                        Text(column == .todo ? "Nada a fazer" : "Vazio")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(drag.target == column ? 0.18 : 0.07)))
        .background(GeometryReader { geometry in
            Color.clear.preference(key: ColumnFramesKey.self, value: [column: geometry.frame(in: .named(BoardDrag.space))])
        })
    }
}

private struct TaskCard: View {
    let task: TaskItem
    let workspace: Workspace?
    @ObservedObject var model: TasksModel
    let deck: Deck
    @ObservedObject var drag: BoardDrag
    var isGhost = false
    @State private var hovered = false

    private var color: Color { workspace?.color ?? .secondary }

    var body: some View {
        // A tap and a drag gesture, not a Button: a Button keeps the mouse.
        // Accessibility still sees a button.
        card
            .opacity(!isGhost && drag.taskID == task.id ? 0.3 : 1)
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(BoardDrag.space))
                .onChanged { value in
                    if drag.taskID != task.id { drag.begin(task.id, at: value.startLocation) }
                    drag.move(to: value.location, tasks: model.tasks)
                }
                .onEnded { _ in
                    if let (column, before) = drag.end() { model.move(task.id, to: column, before: before) }
                })
            .onTapGesture { model.edit(task) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.edit(task) }
            .onHover { hovered = $0 }
            .help(task.details ?? task.title)
            .contextMenu {
                TaskActions(task: task, deck: deck)
                Divider()
                ForEach(TaskItem.Column.allCases.filter { $0 != task.column }, id: \.self) { column in
                    Button("Mover para \(column.title)") { model.move(task.id, to: column) }
                }
                Divider()
                Button("Editar…") { model.edit(task) }
                Button("Apagar", role: .destructive) { model.delete(task.id) }
            }
    }

    private var card: some View {
        HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(Theme.Font.rowTitle)
                    .lineLimit(3)
                    .strikethrough(task.column == .done, color: .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if let workspace { Text(workspace.name).foregroundStyle(color) }
                    if let repo = task.repo {
                        Label(URL(fileURLWithPath: repo).lastPathComponent, systemImage: "folder").labelStyle(.titleAndIcon)
                    }
                    ForEach(Array(task.links.enumerated()), id: \.offset) { _, link in
                        TaskLinkIcon(kind: TaskLinkKind(link))
                    }
                    Spacer(minLength: 0)
                    if task.createdBy == .claude {
                        Text("✳").foregroundStyle(Color.claude).help("Criada pelo Claude")
                    }
                    Text("#\(task.id)").foregroundStyle(.tertiary).monospacedDigit()
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(hovered ? 1 : 0.85))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Color.secondary.opacity(hovered ? 0.35 : 0.15)))
        .opacity(task.column == .done ? 0.65 : 1)
        .contentShape(Rectangle())
    }
}

private struct TaskLinkIcon: View {
    let kind: TaskLinkKind

    var body: some View {
        switch kind {
        case .clickup: Text("ClickUp").fontWeight(.medium)
        case .zoho: Text("Zoho").fontWeight(.medium)
        case .github: Image(systemName: "chevron.left.forwardslash.chevron.right")
        case .other: Image(systemName: "link")
        }
    }
}

/// "Abrir no ClickUp", "Abrir no Zoho", "Abrir terminal no repo"…: the way to
/// each thing the task is tied to.
private struct TaskActions: View {
    let task: TaskItem
    let deck: Deck

    var body: some View {
        ForEach(Array(task.links.enumerated()), id: \.offset) { _, link in
            Button(TaskLinkKind(link).openTitle) { if let url = URL(string: link) { NSWorkspace.shared.open(url) } }
        }
        if let repo = task.repo {
            Button("Abrir terminal no repo") { TaskOpen.terminal(at: repo, deck: deck) }
        }
    }
}

/// A card being dragged inside the board. The board tracks the pointer itself
/// (a drag gesture, not system drag and drop): the card follows it above every
/// column and drops into the column under it, before the card below it.
@MainActor
final class BoardDrag: ObservableObject {
    static let space = "tasks-board"

    @Published private(set) var taskID: Int?
    @Published private(set) var location: CGPoint = .zero
    @Published private(set) var target: TaskItem.Column?
    private(set) var grab: CGSize = .zero
    private(set) var size: CGSize = .zero
    private var before: Int?

    var cardFrames: [Int: CGRect] = [:]
    var columnFrames: [TaskItem.Column: CGRect] = [:]

    func begin(_ id: Int, at start: CGPoint) {
        let frame = cardFrames[id] ?? CGRect(origin: start, size: CGSize(width: 220, height: 50))
        taskID = id
        grab = CGSize(width: start.x - frame.minX, height: start.y - frame.minY)
        size = frame.size
    }

    func move(to point: CGPoint, tasks: [TaskItem]) {
        location = point
        // The column under the pointer, or the nearest one beside it.
        let column = columnFrames.min { abs($0.value.midX - point.x) < abs($1.value.midX - point.x) }?.key
        target = column
        // Before the first card of that column whose middle is below the pointer.
        before = tasks
            .filter { $0.column == column && $0.id != taskID && cardFrames[$0.id] != nil }
            .sorted { $0.order < $1.order }
            .first { cardFrames[$0.id]!.midY > point.y }?.id
    }

    /// Where the card was dropped, and clears the drag.
    func end() -> (TaskItem.Column, Int?)? {
        defer { taskID = nil; target = nil; before = nil }
        guard taskID != nil, let target else { return nil }
        return (target, before)
    }
}

private struct CardFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] { [:] }
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue()) { $1 } }
}

private struct ColumnFramesKey: PreferenceKey {
    static var defaultValue: [TaskItem.Column: CGRect] { [:] }
    static func reduce(value: inout [TaskItem.Column: CGRect], nextValue: () -> [TaskItem.Column: CGRect]) { value.merge(nextValue()) { $1 } }
}

@MainActor
enum TaskOpen {
    static func terminal(at path: String, deck: Deck) {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = path
        deck.add(config: config)
    }
}

// MARK: Editor

private struct TaskEditor: View {
    @State var draft: TaskDraft
    @ObservedObject var model: TasksModel
    let deck: Deck
    @State private var newLink = ""
    @State private var confirmsDelete = false
    @Environment(\.dismiss) private var dismiss

    private var isNew: Bool { draft.taskID == nil }
    private var canSave: Bool { !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isNew ? "Nova tarefa" : "Tarefa #\(draft.taskID!)").font(.title3.weight(.semibold))
                if draft.createdBy == .claude {
                    Text("✳ criada pelo Claude").font(.caption).foregroundStyle(Color.claude)
                }
                Spacer()
            }
            .padding(20)

            if !isNew && (!draft.links.isEmpty || draft.repo != nil) {
                HStack(spacing: 8) {
                    ForEach(Array(draft.links.enumerated()), id: \.offset) { _, link in
                        Button(TaskLinkKind(link).openTitle) { if let url = URL(string: link) { NSWorkspace.shared.open(url) } }
                    }
                    if let repo = draft.repo {
                        Button("Abrir terminal no repo") {
                            model.editing = nil
                            TaskOpen.terminal(at: repo, deck: deck)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            }
            Divider()

            Form {
                TextField("Título", text: $draft.title)
                Picker("Coluna", selection: $draft.column) {
                    ForEach(TaskItem.Column.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Workspace", selection: $draft.workspace) {
                    Text("Nenhum").tag(String?.none)
                    ForEach(deck.workspaces.workspaces) { Text($0.name).tag(String?.some($0.id)) }
                }
                LabeledContent("Descrição") {
                    TextEditor(text: $draft.details)
                        .font(.system(size: 12))
                        .frame(height: 110)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3)))
                }
                LabeledContent("Repo") {
                    HStack {
                        Text(draft.repo.map { ConfigPaths.display(URL(fileURLWithPath: $0)) } ?? "Nenhum")
                            .foregroundStyle(draft.repo == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Escolher…", action: chooseRepo)
                        if draft.repo != nil { Button("Remover") { draft.repo = nil } }
                    }
                }
                LabeledContent("Links") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(draft.links.enumerated()), id: \.offset) { index, link in
                            HStack(spacing: 6) {
                                Text(TaskLinkKind(link).name).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                                Text(link).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                Spacer()
                                Button { draft.links.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help("Remover link")
                            }
                        }
                        HStack {
                            TextField("Colar link do ClickUp, Zoho ou outro", text: $newLink)
                                .onSubmit(addLink)
                            Button("Adicionar", action: addLink).disabled(linkToAdd == nil)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if !isNew {
                    Button("Apagar", role: .destructive) { confirmsDelete = true }
                }
                Spacer()
                Button("Cancelar") { model.editing = nil }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Criar" : "Salvar") {
                    addLink()
                    model.save(draft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 560)
        .confirmationDialog("Apagar a tarefa #\(draft.taskID ?? 0)?", isPresented: $confirmsDelete) {
            Button("Apagar", role: .destructive) { if let id = draft.taskID { model.delete(id) } }
        } message: {
            Text("\(draft.title)\n\nNão dá para desfazer.")
        }
    }

    private var linkToAdd: String? {
        let text = newLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { return nil }
        return text
    }

    private func addLink() {
        guard let link = linkToAdd else { return }
        if !draft.links.contains(link) { draft.links.append(link) }
        newLink = ""
    }

    private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Usar esta pasta"
        panel.directoryURL = draft.repo.map { URL(fileURLWithPath: $0) }
            ?? deck.workspaces.workspace(slug: draft.workspace)?.root
            ?? deck.workspaces.root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.repo = url.path
        if draft.workspace == nil { draft.workspace = deck.workspaces.workspace(containing: url.path)?.id }
    }
}
