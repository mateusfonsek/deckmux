import Darwin
import Foundation

/// One process as the task manager reads it.
public struct ProcessRecord: Equatable, Sendable {
    public let pid: Int
    public let parentPID: Int
    public let groupID: Int
    /// The controlling terminal's device, nil without one.
    public let ttyDevice: Int64?
    public let name: String
    public let path: String?
    /// CPU time used so far, user + system, in nanoseconds.
    public let cpuTime: UInt64
    /// Physical footprint (what Activity Monitor calls Memory), or the
    /// resident size when the footprint cannot be read.
    public let memoryBytes: Int64
    /// Read only for script hosts (node, bun…), to tell which agent they run.
    public var arguments: [String]

    public init(pid: Int, parentPID: Int, groupID: Int, ttyDevice: Int64?, name: String, path: String? = nil,
                cpuTime: UInt64 = 0, memoryBytes: Int64 = 0, arguments: [String] = []) {
        self.pid = pid
        self.parentPID = parentPID
        self.groupID = groupID
        self.ttyDevice = ttyDevice
        self.name = name
        self.path = path
        self.cpuTime = cpuTime
        self.memoryBytes = memoryBytes
        self.arguments = arguments
    }
}

/// Reads every process, as `ps` does: parent, group and terminal from
/// `sysctl(KERN_PROC_ALL)`, which also covers root's processes (a terminal's
/// shell runs under /usr/bin/login, owned by root); CPU and memory from
/// libproc, where allowed (not for other users' processes, which show 0).
public enum ProcessTable {
    public static func read() -> [Int: ProcessRecord] {
        readStructure().mapValues(detailed)
    }

    /// Every process with only what one `sysctl` gives: parent, group,
    /// terminal and the short name. Enough to tell which processes are
    /// Deckmux's; `withDetails` then reads the rest for those alone, instead
    /// of asking libproc about each of the hundreds of processes running.
    public static func readStructure() -> [Int: ProcessRecord] {
        var table: [Int: ProcessRecord] = [:]
        for info in allProcesses() {
            let pid = Int(info.kp_proc.p_pid)
            guard pid > 0 else { continue }
            let device = info.kp_eproc.e_tdev
            let tty: Int64? = device == -1 ? nil : Int64(UInt32(bitPattern: device))  // NODEV: no terminal
            table[pid] = ProcessRecord(pid: pid, parentPID: Int(info.kp_eproc.e_ppid), groupID: Int(info.kp_eproc.e_pgid),
                                       ttyDevice: tty, name: fixedString(info.kp_proc.p_comm))
        }
        return table
    }

    /// The table with name, path, CPU time, memory (and arguments) read for `pids`.
    public static func withDetails(_ table: [Int: ProcessRecord], for pids: some Sequence<Int>) -> [Int: ProcessRecord] {
        var table = table
        for pid in pids {
            if let process = table[pid] { table[pid] = detailed(process) }
        }
        return table
    }

    /// The device of a terminal named like `ttys011` or `/dev/ttys011`.
    public static func ttyDevice(named name: String) -> Int64? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var info = stat()
        guard stat(trimmed.hasPrefix("/dev/") ? trimmed : "/dev/\(trimmed)", &info) == 0 else { return nil }
        return Int64(UInt32(bitPattern: info.st_rdev))
    }

    private static func allProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
            // Room for processes started between the two calls.
            size += 16 * MemoryLayout<kinfo_proc>.stride
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            let result = buffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
            if result == 0 { return Array(buffer.prefix(size / MemoryLayout<kinfo_proc>.stride)) }
            guard errno == ENOMEM else { return [] }
        }
        return []
    }

    private static func detailed(_ process: ProcessRecord) -> ProcessRecord {
        let pid = process.pid
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
        let hasTask = proc_pidinfo(pid_t(pid), PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize

        var memory: Int64 = hasTask ? clamped(task.pti_resident_size) : 0
        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutableBytes(of: &usage) { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return proc_pid_rusage(pid_t(pid), RUSAGE_INFO_V4, base.assumingMemoryBound(to: rusage_info_t?.self))
        }
        if usageResult == 0 { memory = clamped(usage.ri_phys_footprint) }

        let cpuTicks = hasTask ? task.pti_total_user &+ task.pti_total_system : 0
        let name = processName(pid: pid, fallback: process.name)
        let path = processPath(pid: pid)
        var record = ProcessRecord(pid: pid, parentPID: process.parentPID, groupID: process.groupID,
                                   ttyDevice: process.ttyDevice, name: name, path: path,
                                   cpuTime: machToNanoseconds(cpuTicks), memoryBytes: memory)
        if CodingAgents.shouldReadArguments(name: name, path: path) {
            record.arguments = arguments(pid: pid)
        }
        return record
    }

    /// argv from `KERN_PROCARGS2`: argc, the executable path, padding, then the arguments.
    static func arguments(pid: Int) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }      // executable path
        while index < size, buffer[index] == 0 { index += 1 }      // padding
        var arguments: [String] = []
        while index < size, arguments.count < Int(argc) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    private static func processName(pid: Int, fallback: String) -> String {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid_t(pid), &buffer, UInt32(buffer.count)) > 0 else { return fallback }
        let name = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallback : name
    }

    private static func processPath(pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    private static func fixedString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { raw in
            String(decoding: raw[..<(raw.firstIndex(of: 0) ?? raw.endIndex)], as: UTF8.self)
        }
    }

    private static func clamped(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }

    /// `pti_total_*` count Mach time units, not nanoseconds, on Apple silicon.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func machToNanoseconds(_ ticks: UInt64) -> UInt64 {
        guard timebase.denom != 0, timebase.numer != timebase.denom else { return ticks }
        return ticks.multipliedReportingOverflow(by: UInt64(timebase.numer)).partialValue / UInt64(timebase.denom)
    }
}
