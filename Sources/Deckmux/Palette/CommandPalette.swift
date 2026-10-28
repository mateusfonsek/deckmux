import AppKit
import DeckmuxTasks
import SwiftUI

/// ⌘⇧P: one field to reach anything without the mouse: an item,
/// Hoje, a workspace, the next meeting, a task, or a new terminal or task.
struct PaletteEntry: Identifiable {
    enum Section: String, CaseIterable {
        case meeting = "Reunião"
        case items = "Terminais"
        case pages = "Ir para"
        case tasks = "Tarefas"
        case actions = "Ações"
    }

    let id: String
    let section: Section
    let title: String
    var subtitle: String?
    var icon: String
    var color: Color?
    var shortcut: String?
    /// Extra words that match but are not shown.
    var keywords: String = ""
    let run: @MainActor () -> Void
}

@MainActor
enum PaletteEntries {
    static func all(deck: Deck, meetings: NextMeetingModel, tasks: TasksModel) -> [PaletteEntry] {
        var entries: [PaletteEntry] = []
        if let next = meetings.next {
            let workspace = meetings.workspace(of: next)
            let inProgress = next.start <= meetings.now
            entries.append(PaletteEntry(
                id: "meeting", section: .meeting,
                title: (next.meetURL != nil ? "Entrar: " : "Abrir: ") + next.title,
                subtitle: [inProgress ? "agora" : TopBarFormat.when(next, now: meetings.now), TopBarFormat.relative(next, now: meetings.now), workspace?.name]
                    .compactMap { $0 }.joined(separator: " · "),
                icon: "video.fill", color: workspace?.color, keywords: "reuniao meet entrar agenda"
            ) { next.open() })
        }
        let shortcuts = deck.shortcutIndex
        for item in deck.orderedItems {
            let workspace = deck.workspace(of: item)
            entries.append(PaletteEntry(
                id: "item-\(item.id)", section: .items, title: item.displayName,
                subtitle: [workspace?.name, item.branch, item.directory.map { ConfigPaths.display(URL(fileURLWithPath: $0)) }]
                    .compactMap { $0 }.joined(separator: " · "),
                icon: item.runsClaude ? "sparkle" : "terminal.fill", color: item.runsClaude ? Theme.claude : workspace?.color,
                shortcut: shortcuts[item.id].map { "⌘\($0)" },
                keywords: item.attention != nil ? "esperando atencao" : ""
            ) { deck.select(item) })
        }
        entries.append(PaletteEntry(id: "page-today", section: .pages, title: "Hoje", subtitle: "Agenda e tarefas",
                                    icon: "sun.max", shortcut: "⌘0", keywords: "home agenda inicio") { deck.show(.today) })
        entries.append(PaletteEntry(id: "page-workspaces", section: .pages, title: "Workspaces", subtitle: "Nome, cor, CLAUDE.md e MCPs",
                                    icon: "square.stack.3d.up", keywords: "configuracoes ajustes mcp") { deck.showWorkspacesTab() })
        entries.append(PaletteEntry(id: "page-task-manager", section: .pages, title: "Gerenciador de tarefas", subtitle: "Processos, CPU e memória",
                                    icon: "cpu", keywords: "task manager processos cpu memoria consumo encerrar") {
            TaskManagerWindowController.shared?.show()
        })
        for task in tasks.tasks where !task.isArchived() && task.column != .done {
            let workspace = deck.workspaces.workspace(slug: task.workspace)
            entries.append(PaletteEntry(
                id: "task-\(task.id)", section: .tasks, title: task.title,
                subtitle: ["#\(task.id)", task.column.title, workspace?.name].compactMap { $0 }.joined(separator: " · "),
                icon: task.column == .doing ? "circle.lefthalf.filled" : "circle", color: workspace?.color,
                keywords: "tarefa \(task.id) \(task.details ?? "")"
            ) {
                deck.show(.today)
                tasks.edit(task)
            })
        }
        entries.append(PaletteEntry(id: "new-task", section: .actions, title: "Nova tarefa", icon: "plus.square",
                                    keywords: "criar tarefa kanban") {
            deck.show(.today)
            tasks.newTask()
        })
        if let item = deck.selected {
            entries.append(PaletteEntry(id: "open-code", section: .actions, title: "Abrir código",
                                        subtitle: TerminalLabel.folderName(TerminalLayout.repositoryRoot(containing: item.directory) ?? item.directory), icon: TerminalLayout.codeTabIcon,
                                        keywords: "repositorio git diff arquivos alteracoes") {
                item.layout.openCodeForFocusedFolder(inPane: item.layout.bonsplit.focusedPaneId)
            })
        }
        entries.append(PaletteEntry(id: "new-terminal", section: .actions, title: "Novo terminal", subtitle: "Sem workspace",
                                    icon: "plus") { deck.addOutsideWorkspaces() })
        for workspace in deck.workspaces.workspaces {
            entries.append(PaletteEntry(id: "new-terminal-\(workspace.id)", section: .actions, title: "Novo terminal em \(workspace.name)",
                                        icon: "plus", color: workspace.color, keywords: "abrir") { deck.add(in: workspace) })
        }
        return entries
    }

    /// Entries matching `query`, best first; every word must match.
    static func filter(_ entries: [PaletteEntry], query: String) -> [PaletteEntry] {
        let words = normalize(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.compactMap { entry -> (PaletteEntry, Int)? in
            let title = normalize(entry.title)
            let haystack = [title, normalize(entry.subtitle ?? ""), normalize(entry.keywords)].joined(separator: " ")
            var score = 0
            for word in words {
                if title.hasPrefix(word) { score += 30 }
                else if title.contains(" " + word) || title.contains(word) { score += 20 }
                else if haystack.contains(word) { score += 8 }
                else if isSubsequence(word, of: title) { score += 3 }
                else { return nil }
            }
            return (entry, score)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        return needle.allSatisfy { char in
            while let next = iterator.next() { if next == char { return true } }
            return false
        }
    }
}

struct CommandPaletteView: View {
    let entries: [PaletteEntry]
    let close: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var results: [PaletteEntry] { PaletteEntries.filter(entries, query: query) }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                TextField("Buscar terminais, tarefas, ações…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { run(results) }
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        if results.isEmpty {
                            Text("Nada encontrado").font(Theme.Font.body).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 28)
                        }
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                            if index == 0 || results[index - 1].section != entry.section {
                                Text(entry.section.rawValue.uppercased())
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, index == 0 ? 6 : 12)
                                    .padding(.bottom, 3)
                            }
                            PaletteRow(entry: entry, isSelected: index == selection)
                                .id(index)
                                .onTapGesture {
                                    selection = index
                                    run(results)
                                }
                        }
                    }
                    .padding(8)
                }
                .frame(height: 380)
                .onChange(of: selection) { _, value in proxy.scrollTo(value) }
            }
            Divider()
            HStack(spacing: 14) {
                hint("↑↓", "navegar")
                hint("↩", "abrir")
                hint("esc", "fechar")
                Spacer()
                HStack(spacing: 4) {
                    DeckmuxMark(size: 12)
                    Text("Deckmux").font(Theme.Font.caption)
                }
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 32)
        }
        .frame(width: 620)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Color.primary.opacity(0.12)))
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, max(results.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
    }

    private func run(_ results: [PaletteEntry]) {
        guard results.indices.contains(selection) else { return }
        let entry = results[selection]
        close()
        DispatchQueue.main.async { MainActor.assumeIsolated { entry.run() } }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text(label).font(Theme.Font.caption)
        }
        .foregroundStyle(.secondary)
    }
}

private struct PaletteRow: View {
    let entry: PaletteEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: entry.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(entry.color ?? .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(Theme.Font.rowTitle).lineLimit(1)
                if let subtitle = entry.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = entry.shortcut {
                Text(shortcut).font(Theme.Font.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(isSelected ? Color.primary.opacity(0.10) : .clear))
        .contentShape(Rectangle())
    }
}

/// A floating panel over the window, so the palette sits above the terminals'
/// Metal layers and takes the keyboard.
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init(content: NSView) {
        super.init(contentRect: content.frame, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        level = .floating
        contentView = content
    }

    override func resignKey() {
        super.resignKey()
        close()
    }

    override func cancelOperation(_ sender: Any?) { close() }

    /// Called once the panel closes, however it closed.
    var onClose: (() -> Void)?

    override func close() {
        guard isVisible else { return }
        parent?.removeChildWindow(self)
        super.close()
        onClose?()
    }
}
