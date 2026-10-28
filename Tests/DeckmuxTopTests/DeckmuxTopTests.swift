import Foundation
import Testing
@testable import DeckmuxTop

private let app = 100
private let tty: Int64 = 0x1000000b

private func process(_ pid: Int, parent: Int, group: Int? = nil, tty: Int64? = nil, name: String = "zsh",
                     path: String? = nil, cpu: UInt64 = 0, memory: Int64 = 0, arguments: [String] = []) -> ProcessRecord {
    ProcessRecord(pid: pid, parentPID: parent, groupID: group ?? pid, ttyDevice: tty, name: name, path: path,
                  cpuTime: cpu, memoryBytes: memory, arguments: arguments)
}

private func table(_ records: ProcessRecord...) -> [Int: ProcessRecord] {
    Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) })
}

// MARK: Attribution

@Test func terminalOwnsItsShellAndWhatRunsUnderIt() {
    let t = table(
        process(app, parent: 1, name: "Deckmux"),
        process(200, parent: app, tty: tty, name: "login"),
        process(201, parent: 200, tty: tty),
        process(202, parent: 201, group: 202, tty: tty, name: "claude"),
        // Off the tty but under the shell: a daemon Claude started.
        process(203, parent: 202, name: "node")
    )
    #expect(TerminalAttribution.processes(of: ["t": tty], appPID: app, in: t)["t"] == [200, 201, 202, 203])
}

@Test func processThatOnlySharesTheTTYIsNotCounted() {
    let t = table(
        process(app, parent: 1, name: "Deckmux"),
        process(201, parent: app, tty: tty),
        // Reparented to launchd from some other app's terminal: same device, no link.
        process(300, parent: 1, group: 300, tty: tty, name: "stray")
    )
    #expect(TerminalAttribution.processes(of: ["t": tty], appPID: app, in: t)["t"] == [201])
}

@Test func backgroundJobWhoseParentLeftStaysWithItsGroup() {
    let t = table(
        process(app, parent: 1, name: "Deckmux"),
        process(201, parent: app, group: 201, tty: tty),
        process(210, parent: 1, group: 201, tty: tty, name: "sleep")
    )
    #expect(TerminalAttribution.processes(of: ["t": tty], appPID: app, in: t)["t"] == [201, 210])
}

@Test func terminalsDoNotShareProcesses() {
    let other: Int64 = 0x1000000c
    let t = table(
        process(app, parent: 1, name: "Deckmux"),
        process(201, parent: app, tty: tty),
        process(301, parent: app, tty: other)
    )
    let owned = TerminalAttribution.processes(of: ["a": tty, "b": other], appPID: app, in: t)
    #expect(owned["a"] == [201])
    #expect(owned["b"] == [301])
}

// MARK: CPU

@Test func cpuIsTimeSpentOverTimeElapsed() {
    let tracker = CPUTracker()
    let second: UInt64 = 1_000_000_000
    #expect(tracker.percentages(for: table(process(1, parent: 0, cpu: 0)), now: 10 * second)[1] == 0)
    // Half a core for two seconds.
    #expect(tracker.percentages(for: table(process(1, parent: 0, cpu: second)), now: 12 * second)[1] == 50)
    // Too soon: keeps the last value.
    #expect(tracker.percentages(for: table(process(1, parent: 0, cpu: 2 * second)), now: 12 * second + 100)[1] == 50)
}

@Test func reusedPIDStartsOver() {
    let tracker = CPUTracker()
    let second: UInt64 = 1_000_000_000
    _ = tracker.percentages(for: table(process(1, parent: 0, cpu: 5 * second)), now: 10 * second)
    #expect(tracker.percentages(for: table(process(1, parent: 0, cpu: 0)), now: 12 * second)[1] == 0)
}

// MARK: Coding agents

@Test func recognizesAgentsByNameAndByScript() {
    #expect(CodingAgents.agent(for: process(1, parent: 0, name: "claude"))?.id == "claude")
    // Claude Code's native binary is named after its version.
    let native = process(2, parent: 0, name: "2.1.3", path: "/Users/u/.local/share/claude/versions/2.1.3")
    #expect(CodingAgents.shouldReadArguments(name: "2.1.3", path: native.path))
    #expect(CodingAgents.agent(for: native)?.id == "claude")
    let gemini = process(3, parent: 0, name: "node", arguments: ["node", "/opt/homebrew/bin/gemini"])
    #expect(CodingAgents.agent(for: gemini)?.id == "gemini")
    #expect(CodingAgents.agent(for: process(4, parent: 0, name: "node", arguments: ["node", "server.js"])) == nil)
    #expect(CodingAgents.agent(for: process(5, parent: 0, name: "ollama", arguments: ["ollama", "serve"])) == nil)
    #expect(CodingAgents.agent(for: process(6, parent: 0, name: "ollama", arguments: ["ollama", "run", "llama3"]))?.id == "ollama")
}

@Test func agentTotalsCountTheAgentAndItsChildren() {
    let t = table(
        process(10, parent: 1, name: "claude", memory: 100),
        process(11, parent: 10, name: "node", memory: 50, arguments: ["node", "mcp.js"]),
        process(20, parent: 1, name: "zsh", memory: 10)
    )
    let rows = TaskTotals.agents(table: t, cpu: [10: 4, 11: 1], pids: [10, 11, 20])
    #expect(rows.count == 1)
    #expect(rows[0].title == "Claude Code")
    #expect(rows[0].resources == Resources(cpuPercent: 5, memoryBytes: 150, processIDs: [10, 11]))
    #expect(rows[0].detail == "2 processos")
}

@Test func programTotalsOnlyRepeatedPrograms() {
    let t = table(process(1, parent: 0, name: "node", memory: 1), process(2, parent: 0, name: "node", memory: 2),
                  process(3, parent: 0, name: "zsh", memory: 4))
    let rows = TaskTotals.programs(table: t, cpu: [:], pids: [1, 2, 3])
    #expect(rows.map(\.title) == ["node"])
    #expect(rows[0].resources.memoryBytes == 3)
}

// MARK: Rows

private func row(_ id: String, _ level: Int, cpu: Double, memory: Int64 = 0) -> TaskRow {
    TaskRow(id: id, kind: .item, level: level, title: id, resources: Resources(cpuPercent: cpu, memoryBytes: memory, processIDs: []))
}

@Test func sortingKeepsTheHierarchy() {
    let rows = [row("janela", 0, cpu: 9), row("a", 1, cpu: 1), row("a1", 2, cpu: 1), row("a2", 2, cpu: 5),
                row("b", 1, cpu: 8), row("b1", 2, cpu: 8)]
    #expect(TaskSortOrder.standard.sorted(rows).map(\.id) == ["janela", "b", "b1", "a", "a2", "a1"])
    let byName = TaskSortOrder.standard.toggled(for: .name)
    #expect(byName == TaskSortOrder(column: .name, direction: .ascending))
    #expect(byName.sorted(rows).map(\.id) == ["janela", "a", "a1", "a2", "b", "b1"])
    #expect(byName.toggled(for: .name).direction == .descending)
}

@Test func formatsLikeCmux() {
    #expect(TaskFormat.cpu(12.345) == "12.3%")
    #expect(TaskFormat.cpu(-1) == "0.0%")
    #expect(TaskFormat.bytes(512) == "512 B")
    #expect(TaskFormat.bytes(141_767_475) == "135.2 MB")
    #expect(TaskFormat.bytes(2_684_354_560) == "2.5 GB")
    #expect(TaskFormat.processCount(1) == "1 processo")
}

@Test func neverEndsTheAppOrLaunchd() {
    let r = TaskRow(id: "x", kind: .terminal, level: 0, title: "x",
                    resources: Resources(cpuPercent: 0, memoryBytes: 0, processIDs: [1, app, 201]), rootProcessIDs: [app, 201])
    #expect(r.killableProcessIDs(appPID: app) == [201])
    #expect(r.gracefulProcessIDs(appPID: app) == [201])
}

// MARK: Reading the real table

@Test func readsRootOwnedProcesses() {
    // A terminal's shell runs under /usr/bin/login, owned by root: the chain
    // from the shell up to the app goes through it.
    #expect(ProcessTable.read()[1]?.name == "launchd")
}

@Test func readsThisProcess() throws {
    let me = Int(getpid())
    let t = ProcessTable.read()
    let record = try #require(t[me])
    #expect(record.parentPID > 0)
    #expect(record.memoryBytes > 0)
    #expect(!record.name.isEmpty)
}

@Test func readsDetailsOnlyForTheGivenProcesses() throws {
    let me = Int(getpid())
    let structure = ProcessTable.readStructure()
    let bare = try #require(structure[me])
    #expect(bare.parentPID > 0)
    #expect(bare.memoryBytes == 0)
    let table = ProcessTable.withDetails(structure, for: [me])
    #expect(try #require(table[me]).memoryBytes > 0)
    #expect(try #require(table[bare.parentPID]).memoryBytes == 0)
    #expect(table.count == structure.count)
}
