import Foundation

/// Which processes belong to each terminal. A terminal's tty is not proof:
/// a process reparented to launchd keeps the tty it was started from (cmux
/// issue 11004). A process counts when it is on the terminal's tty and
/// descends from the app (the shell Deckmux opened and what runs under it),
/// when it descends from one that counts (also off the tty), or when it is in
/// the process group of one that counts (a background job whose parent left).
public enum TerminalAttribution {
    public static func processes<Key: Hashable>(of terminals: [Key: Int64], appPID: Int,
                                                in table: [Int: ProcessRecord]) -> [Key: Set<Int>] {
        var children: [Int: [Int]] = [:]
        for process in table.values { children[process.parentPID, default: []].append(process.pid) }
        var descendsFromApp: [Int: Bool] = [:]

        func isUnderApp(_ pid: Int) -> Bool {
            var chain: [Int] = []
            var current = pid
            var answer = false
            while true {
                if let known = descendsFromApp[current] { answer = known; break }
                guard let process = table[current], current > 1 else { answer = false; break }
                if process.parentPID == appPID { answer = true; chain.append(current); break }
                chain.append(current)
                current = process.parentPID
                if chain.count > table.count { break }
            }
            for pid in chain { descendsFromApp[pid] = answer }
            return answer
        }

        func withDescendants(_ roots: Set<Int>) -> Set<Int> {
            var owned = roots
            var queue = Array(roots)
            while let pid = queue.popLast() {
                for child in children[pid] ?? [] where owned.insert(child).inserted { queue.append(child) }
            }
            return owned
        }

        var result: [Key: Set<Int>] = [:]
        for (key, device) in terminals {
            let onTTY = table.values.filter { $0.ttyDevice == device && $0.pid != appPID }
            var owned = withDescendants(Set(onTTY.filter { isUnderApp($0.pid) }.map(\.pid)))
            let groups = Set(owned.compactMap { table[$0]?.groupID })
            let jobs = onTTY.filter { !owned.contains($0.pid) && groups.contains($0.groupID) }.map(\.pid)
            owned.formUnion(withDescendants(Set(jobs)))
            result[key] = owned
        }
        return result
    }
}
