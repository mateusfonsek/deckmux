import AppKit
import Combine
import OSLog
import DeckmuxTop
import SwiftUI

/// What the task manager needs from the deck, taken on the main thread so
/// the reading and the rows can be done off it.
struct TaskManagerLayout: Sendable {
    struct Terminal: Sendable {
        let id: UUID
        let title: String
        let ttyName: String?
        let device: Int64?
        let isSelected: Bool
        let foregroundPID: Int?
    }

    struct Pane: Sendable {
        let id: String
        let isFocused: Bool
        let terminals: [Terminal]
    }

    struct Item: Sendable {
        let id: UUID
        let title: String
        let workspaceID: String?
        let isSelected: Bool
        let panes: [Pane]
    }

    struct WorkspaceGroup: Sendable {
        let id: String
        let name: String
        let items: [Item]
    }

    let windowIsKey: Bool
    let windowIsVisible: Bool
    let rootItems: [Item]
    let workspaces: [WorkspaceGroup]

    var allItems: [Item] { rootItems + workspaces.flatMap(\.items) }

    @MainActor init(deck: Deck, window: NSWindow?) {
        windowIsKey = window?.isKeyWindow ?? false
        windowIsVisible = window?.isVisible ?? false
        func item(_ item: DeckItem, workspace: String?) -> Item {
            let layout = item.layout
            let panes = layout.bonsplit.allPaneIds.map { pane in
                let selectedTab = layout.bonsplit.selectedTabId(inPane: pane)
                let terminals = layout.bonsplit.tabIds(inPane: pane).compactMap { tab -> Terminal? in
                    guard let surface = layout.surface(for: tab) else { return nil }  // code tabs have no processes
                    let tty = surface.surfaceModel?.ttyName
                    return Terminal(id: surface.id,
                                    title: TerminalLabel.tabName(pwd: surface.pwd, title: surface.title, runsClaude: layout.runsClaude(surface)),
                                    ttyName: tty, device: tty.flatMap(ProcessTable.ttyDevice(named:)),
                                    isSelected: selectedTab == tab, foregroundPID: surface.surfaceModel?.foregroundPID)
                }
                return Pane(id: "\(pane.id)", isFocused: layout.bonsplit.focusedPaneId == pane, terminals: terminals)
            }
            return Item(id: item.id, title: item.displayName, workspaceID: workspace,
                        isSelected: deck.page == nil && deck.selectedID == item.id, panes: panes)
        }
        rootItems = deck.rootItems.map { item($0, workspace: nil) }
        workspaces = deck.workspaces.workspaces.map { workspace in
            WorkspaceGroup(id: workspace.id, name: workspace.name, items: deck.items(in: workspace).map { item($0, workspace: workspace.id) })
        }
    }
}

/// One reading turned into rows, as the window shows them.
struct TaskManagerSnapshot: Sendable {
    var hierarchy: [TaskRow] = []
    var agents: [TaskRow] = []
    var programs: [TaskRow] = []
    var total = Resources.zero
    var updated: Date?

    var updatedText: String {
        updated.map { Self.timeFormatter.string(from: $0) } ?? "—"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()

    /// Window > workspace > item > pane (only with more than one) > terminal > processes.
    /// Each terminal's processes. Needs only the table's structure.
    static func ownedProcesses(layout: TaskManagerLayout, table: [Int: ProcessRecord], appPID: Int) -> [UUID: Set<Int>] {
        var devices: [UUID: Int64] = [:]
        for item in layout.allItems {
            for terminal in item.panes.flatMap(\.terminals) { if let device = terminal.device { devices[terminal.id] = device } }
        }
        return TerminalAttribution.processes(of: devices, appPID: appPID, in: table)
    }

    static func build(layout: TaskManagerLayout, table: [Int: ProcessRecord], owned: [UUID: Set<Int>], cpu: [Int: Double],
                      appPID: Int, includesProcesses: Bool, now: Date) -> TaskManagerSnapshot {
        func resources(_ pids: some Sequence<Int>) -> Resources { Resources(pids: pids, table: table, cpu: cpu) }
        func pids(_ terminals: [TaskManagerLayout.Terminal]) -> Set<Int> {
            terminals.reduce(into: Set<Int>()) { $0.formUnion(owned[$1.id] ?? []) }
        }

        var rows: [TaskRow] = []
        let allTerminalPIDs = owned.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
        let windowPIDs = allTerminalPIDs.union([appPID])
        let windowDetail = [layout.windowIsKey ? "Janela ativa" : nil, layout.windowIsVisible ? nil : "Escondida"].compactMap { $0 }
        let total = resources(windowPIDs)
        rows.append(TaskRow(id: "window", kind: .window, level: 0, title: "Janela", detail: windowDetail.joined(separator: " / "),
                            resources: total))
        if includesProcesses, table[appPID] != nil {
            rows.append(processRow(appPID, level: 1, context: "window", table: table, cpu: cpu, itemID: nil, terminalID: nil))
        }

        func appendItem(_ item: TaskManagerLayout.Item, level: Int) {
            let terminals = item.panes.flatMap(\.terminals)
            rows.append(TaskRow(id: "item:\(item.id)", kind: .item, level: level, title: item.title,
                                detail: item.isSelected ? "Selecionado" : "", resources: resources(pids(terminals)),
                                itemID: item.id, workspaceID: item.workspaceID))
            let split = item.panes.count > 1
            for pane in item.panes where !pane.terminals.isEmpty {
                if split {
                    rows.append(TaskRow(id: "pane:\(item.id):\(pane.id)", kind: .pane, level: level + 1, title: "Painel",
                                        detail: pane.isFocused ? "Em foco" : "", resources: resources(pids(pane.terminals)),
                                        itemID: item.id, workspaceID: item.workspaceID))
                }
                for terminal in pane.terminals {
                    appendTerminal(terminal, item: item, level: level + (split ? 2 : 1))
                }
            }
        }

        func appendTerminal(_ terminal: TaskManagerLayout.Terminal, item: TaskManagerLayout.Item, level: Int) {
            let mine = owned[terminal.id] ?? []
            let roots = mine.filter { pid in table[pid].map { !mine.contains($0.parentPID) } ?? false }
            let foregroundGroup = terminal.foregroundPID.flatMap { table[$0]?.groupID }
            let tty = terminal.ttyName.map { $0.hasPrefix("/dev/") ? String($0.dropFirst(5)) : $0 }
            let detail = ["Terminal", terminal.isSelected ? "Selecionado" : nil, tty].compactMap { $0 }
            rows.append(TaskRow(id: "terminal:\(terminal.id)", kind: .terminal, level: level, title: terminal.title,
                                detail: detail.joined(separator: " / "), resources: resources(mine),
                                itemID: item.id, terminalID: terminal.id, workspaceID: item.workspaceID,
                                rootProcessIDs: roots.sorted(), foregroundGroupIDs: foregroundGroup.map { [$0] } ?? []))
            guard includesProcesses else { return }
            for pid in mine.sorted() {
                rows.append(processRow(pid, level: level + 1, context: "\(terminal.id)", table: table, cpu: cpu,
                                       itemID: item.id, terminalID: terminal.id))
            }
        }

        for item in layout.rootItems { appendItem(item, level: 1) }
        for workspace in layout.workspaces where !workspace.items.isEmpty {
            let itemPIDs = workspace.items.reduce(into: Set<Int>()) { $0.formUnion(pids($1.panes.flatMap(\.terminals))) }
            let shown = workspace.items.first(where: \.isSelected) ?? workspace.items.first
            rows.append(TaskRow(id: "workspace:\(workspace.id)", kind: .workspace, level: 1, title: workspace.name,
                                detail: workspace.items.contains(where: \.isSelected) ? "Selecionado" : "",
                                resources: resources(itemPIDs), itemID: shown?.id, workspaceID: workspace.id))
            for item in workspace.items { appendItem(item, level: 2) }
        }

        return TaskManagerSnapshot(
            hierarchy: rows,
            agents: includesProcesses ? TaskTotals.agents(table: table, cpu: cpu, pids: allTerminalPIDs) : [],
            programs: includesProcesses ? TaskTotals.programs(table: table, cpu: cpu, pids: windowPIDs) : [],
            total: total, updated: now)
    }

    private static func processRow(_ pid: Int, level: Int, context: String, table: [Int: ProcessRecord], cpu: [Int: Double],
                                   itemID: UUID?, terminalID: UUID?) -> TaskRow {
        TaskRow(id: "process:\(context):\(pid)", kind: .process, level: level, title: table[pid]?.name ?? "Processo \(pid)",
                detail: "PID \(pid)", resources: Resources(pids: [pid], table: table, cpu: cpu),
                itemID: itemID, terminalID: terminalID, processID: pid, rootProcessIDs: [pid])
    }
}

/// Reads the processes every 3 s while the window is on screen, off the
/// main thread, and publishes the rows sorted.
@MainActor
final class TaskManagerModel: ObservableObject {
    @Published private(set) var snapshot = TaskManagerSnapshot()
    @Published private(set) var isInitialLoading = true
    @Published private(set) var isRefreshing = false
    @Published var includesProcesses = false {
        didSet { if includesProcesses != oldValue { refresh() } }
    }
    @Published private(set) var sortOrder = TaskSortOrder.standard

    var sortedRows: [TaskRow] { sortOrder.sorted(snapshot.hierarchy) }
    var sortedAgentRows: [TaskRow] { sortOrder.sorted(snapshot.agents) }
    var sortedProgramRows: [TaskRow] { sortOrder.sorted(snapshot.programs) }

    let deck: Deck
    /// Colors of the workspace rows' icons.
    private(set) var workspaceColors: [String: Color] = [:]
    private weak var mainWindow: NSWindow?
    private let queue = DispatchQueue(label: "dev.fonsek.deckmux.task-manager", qos: .utility)
    /// Only touched on `queue`.
    private let tracker = CPUTracker()
    private var timer: Timer?
    private var pending = false
    #if DEBUG
    var logsRows = false
    private static let logger = Logger(subsystem: "dev.fonsek.deckmux", category: "task-manager")
    #endif
    /// A change (Processos ticked) came while reading: read again right after.
    private var readAgain = false

    init(deck: Deck, mainWindow: NSWindow?) {
        self.deck = deck
        self.mainWindow = mainWindow
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        // The first read only primes CPU; a second one a second later has real numbers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 0.3
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func sort(by column: TaskSortOrder.Column) {
        sortOrder = sortOrder.toggled(for: column)
    }

    func refresh() {
        guard !pending else { readAgain = true; return }
        pending = true
        isRefreshing = true
        workspaceColors = Dictionary(uniqueKeysWithValues: deck.workspaces.workspaces.map { ($0.id, $0.color) })
        let layout = TaskManagerLayout(deck: deck, window: mainWindow)
        let includesProcesses = includesProcesses
        let appPID = Int(getpid())
        let primed = !isInitialLoading || snapshot.updated != nil
        queue.async { [tracker] in
            // Details (CPU, memory, names) only for Deckmux's own processes.
            let structure = ProcessTable.readStructure()
            let owned = TaskManagerSnapshot.ownedProcesses(layout: layout, table: structure, appPID: appPID)
            let mine = owned.values.reduce(into: Set([appPID])) { $0.formUnion($1) }
            let table = ProcessTable.withDetails(structure, for: mine)
            let cpu = tracker.percentages(for: table.filter { mine.contains($0.key) }, now: DispatchTime.now().uptimeNanoseconds)
            let snapshot = TaskManagerSnapshot.build(layout: layout, table: table, owned: owned, cpu: cpu, appPID: appPID,
                                                     includesProcesses: includesProcesses, now: Date())
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.snapshot = snapshot
                #if DEBUG
                if self.logsRows {
                    for row in self.sortOrder.sorted(snapshot.agents + snapshot.programs) + self.sortedRows {
                        let text = "\(String(repeating: "  ", count: row.level))\(row.kind.rawValue) \(row.title) [\(row.detail)] "
                            + "\(TaskFormat.cpu(row.resources.cpuPercent)) \(TaskFormat.bytes(row.resources.memoryBytes)) \(row.resources.processIDs)"
                        Self.logger.info("\(text, privacy: .public)")
                    }
                }
                #endif
                if primed { self.isInitialLoading = false }
                self.isRefreshing = false
                self.pending = false
                if self.readAgain {
                    self.readAgain = false
                    self.refresh()
                }
            }
        }
    }
}
