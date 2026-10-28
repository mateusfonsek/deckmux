import Foundation

/// CPU, memory and process count of a row: its own processes plus everything under it.
public struct Resources: Equatable, Sendable {
    public static let zero = Resources(cpuPercent: 0, memoryBytes: 0, processIDs: [])

    public let cpuPercent: Double
    public let memoryBytes: Int64
    /// Sorted and without repeats, so equal rows compare equal.
    public let processIDs: [Int]
    public var processCount: Int { processIDs.count }

    public init(cpuPercent: Double, memoryBytes: Int64, processIDs: [Int]) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.processIDs = Array(Set(processIDs)).sorted()
    }

    /// The processes in `pids` that are still in `table`.
    public init(pids: some Sequence<Int>, table: [Int: ProcessRecord], cpu: [Int: Double]) {
        var cpuPercent = 0.0
        var memory: Int64 = 0
        var present: [Int] = []
        for pid in Set(pids) {
            guard let process = table[pid] else { continue }
            cpuPercent += cpu[pid] ?? 0
            let (sum, overflow) = memory.addingReportingOverflow(process.memoryBytes)
            memory = overflow ? .max : sum
            present.append(pid)
        }
        self.init(cpuPercent: cpuPercent, memoryBytes: memory, processIDs: present)
    }
}

/// One line of the task manager. `level` is the indent in the hierarchy.
public struct TaskRow: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case window, workspace, item, pane, terminal, process, programTotal, codingAgent
    }

    public let id: String
    public let kind: Kind
    public let level: Int
    public let title: String
    public let detail: String
    public let resources: Resources
    /// What a click shows: a sidebar item, and a terminal in it.
    public let itemID: UUID?
    public let terminalID: UUID?
    public let workspaceID: String?
    /// The process of a process row.
    public let processID: Int?
    /// What "Encerrar processo…" asks to end first, gently.
    public let rootProcessIDs: [Int]
    public let foregroundGroupIDs: [Int]

    public init(id: String, kind: Kind, level: Int, title: String, detail: String = "", resources: Resources,
                itemID: UUID? = nil, terminalID: UUID? = nil, workspaceID: String? = nil, processID: Int? = nil,
                rootProcessIDs: [Int] = [], foregroundGroupIDs: [Int] = []) {
        self.id = id
        self.kind = kind
        self.level = level
        self.title = title
        self.detail = detail
        self.resources = resources
        self.itemID = itemID
        self.terminalID = terminalID
        self.workspaceID = workspaceID
        self.processID = processID
        self.rootProcessIDs = rootProcessIDs
        self.foregroundGroupIDs = foregroundGroupIDs
    }

    public var canShowItem: Bool { itemID != nil }
    public var canShowTerminal: Bool { itemID != nil && terminalID != nil }

    /// Every process the row counts, never the app itself or launchd.
    public func killableProcessIDs(appPID: Int) -> [Int] {
        Self.safe(resources.processIDs + [processID].compactMap { $0 }, appPID: appPID)
    }

    /// Asked to end first: the roots (a terminal's shell, an agent's processes),
    /// else the row's process, else all of them.
    public func gracefulProcessIDs(appPID: Int) -> [Int] {
        var ids = rootProcessIDs
        if ids.isEmpty, let processID { ids = [processID] }
        if ids.isEmpty { ids = resources.processIDs }
        return Self.safe(ids, appPID: appPID)
    }

    public func gracefulGroupIDs(appGroupID: Int) -> [Int] {
        Array(Set(foregroundGroupIDs)).filter { $0 > 1 && $0 != appGroupID }.sorted()
    }

    private static func safe(_ ids: [Int], appPID: Int) -> [Int] {
        Array(Set(ids)).filter { $0 > 1 && $0 != appPID }.sorted()
    }
}

/// Column order of the table: a click on a column sorts by it, a second
/// click flips the direction. Rows are sorted among their siblings, so the
/// hierarchy stays.
public struct TaskSortOrder: Equatable, Sendable {
    public enum Column: Sendable {
        case name, cpu, memory, processes

        var defaultDirection: Direction { self == .name ? .ascending : .descending }
    }

    public enum Direction: Sendable {
        case ascending, descending
    }

    public static let standard = TaskSortOrder(column: .cpu, direction: .descending)

    public let column: Column
    public let direction: Direction

    public init(column: Column, direction: Direction) {
        self.column = column
        self.direction = direction
    }

    public func toggled(for selected: Column) -> TaskSortOrder {
        selected == column
            ? TaskSortOrder(column: column, direction: direction == .ascending ? .descending : .ascending)
            : TaskSortOrder(column: selected, direction: selected.defaultDirection)
    }

    public func sorted(_ rows: [TaskRow]) -> [TaskRow] {
        guard !rows.isEmpty else { return rows }
        var index = 0
        let top = rows.map(\.level).min() ?? 0
        return flatten(sort(parse(rows, index: &index, level: top)))
    }

    private struct Node {
        let row: TaskRow
        let children: [Node]
    }

    private func parse(_ rows: [TaskRow], index: inout Int, level: Int) -> [Node] {
        var nodes: [Node] = []
        while index < rows.count, rows[index].level == level {
            let row = rows[index]
            index += 1
            var children: [Node] = []
            while index < rows.count, rows[index].level > row.level {
                children += parse(rows, index: &index, level: rows[index].level)
            }
            nodes.append(Node(row: row, children: children))
        }
        return nodes
    }

    private func sort(_ nodes: [Node]) -> [Node] {
        nodes.enumerated().sorted { lhs, rhs in
            let order = compare(lhs.element.row, rhs.element.row)
            if order != .orderedSame {
                return direction == .ascending ? order == .orderedAscending : order == .orderedDescending
            }
            return lhs.offset < rhs.offset
        }
        .map { Node(row: $0.element.row, children: sort($0.element.children)) }
    }

    private func flatten(_ nodes: [Node]) -> [TaskRow] {
        nodes.flatMap { [$0.row] + flatten($0.children) }
    }

    private func compare(_ lhs: TaskRow, _ rhs: TaskRow) -> ComparisonResult {
        switch column {
        case .name: lhs.title.localizedStandardCompare(rhs.title)
        case .cpu: Self.compare(lhs.resources.cpuPercent, rhs.resources.cpuPercent)
        case .memory: Self.compare(lhs.resources.memoryBytes, rhs.resources.memoryBytes)
        case .processes: Self.compare(lhs.resources.processCount, rhs.resources.processCount)
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
    }
}

/// Numbers as cmux shows them: "12.3%", "135.2 MB" (1024-based), "3 processos".
public enum TaskFormat {
    public static func cpu(_ value: Double) -> String {
        String(format: "%.1f%%", max(0, value))
    }

    public static func bytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes))
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(Int(value)) B" : String(format: "%.1f %@", value, units[unit])
    }

    public static func processCount(_ count: Int) -> String {
        count == 1 ? "1 processo" : "\(count) processos"
    }
}

/// The "Program Totals" and "Coding Agents" sections.
public enum TaskTotals {
    /// Programs running in more than one process, summed by name, by name.
    public static func programs(table: [Int: ProcessRecord], cpu: [Int: Double], pids: Set<Int>) -> [TaskRow] {
        var byName: [String: (title: String, pids: [Int])] = [:]
        for pid in pids {
            guard let title = table[pid]?.name.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { continue }
            byName[title.lowercased(), default: (title, [])].pids.append(pid)
        }
        return byName.values
            .filter { $0.pids.count > 1 }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { entry in
                let resources = Resources(pids: entry.pids, table: table, cpu: cpu)
                return TaskRow(id: "program:\(entry.title.lowercased())", kind: .programTotal, level: 0, title: entry.title,
                               detail: TaskFormat.processCount(resources.processCount), resources: resources,
                               rootProcessIDs: resources.processIDs)
            }
    }

    /// Each agent with its processes and everything under them, in list order.
    public static func agents(table: [Int: ProcessRecord], cpu: [Int: Double], pids: Set<Int>) -> [TaskRow] {
        var children: [Int: [Int]] = [:]
        for pid in pids { if let parent = table[pid]?.parentPID { children[parent, default: []].append(pid) } }
        var roots: [String: [Int]] = [:]
        for pid in pids {
            guard let process = table[pid], let agent = CodingAgents.agent(for: process) else { continue }
            // A wrapper's child running the same agent is counted through the wrapper.
            if let parent = table[process.parentPID], pids.contains(parent.pid),
               CodingAgents.agent(for: parent)?.id == agent.id { continue }
            roots[agent.id, default: []].append(pid)
        }
        return CodingAgents.all.compactMap { agent in
            guard let agentRoots = roots[agent.id] else { return nil }
            var owned = Set(agentRoots)
            var queue = agentRoots
            while let pid = queue.popLast() {
                for child in children[pid] ?? [] where owned.insert(child).inserted { queue.append(child) }
            }
            let resources = Resources(pids: owned, table: table, cpu: cpu)
            guard resources.processCount > 0 else { return nil }
            return TaskRow(id: "agent:\(agent.id)", kind: .codingAgent, level: 0, title: agent.name,
                           detail: TaskFormat.processCount(resources.processCount), resources: resources,
                           rootProcessIDs: agentRoots.sorted())
        }
    }
}
