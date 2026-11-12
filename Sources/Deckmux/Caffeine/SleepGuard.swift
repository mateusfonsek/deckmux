import DeckmuxCaffeine
import Foundation
import IOKit.pwr_mgt
import OSLog

/// The only part of Deckmux that changes how the Mac sleeps: an idle-sleep
/// assertion (lid open, screen off) plus `pmset disablesleep` (lid closed),
/// and a watcher process that turns sleep back on if Deckmux dies.
@MainActor
final class SleepGuard {
    nonisolated private static let logger = Logger(subsystem: "dev.fonsek.deckmux", category: "cafe")

    enum Failure: Error { case denied(String) }

    private var assertion: IOPMAssertionID = 0
    private var watcher: Process?
    private(set) var isEngaged = false

    /// Nothing stays half on: if pmset fails, the assertion is dropped and this throws.
    func engage() throws {
        guard !isEngaged else { return }
        var id: IOPMAssertionID = 0
        let created = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                  IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                  "Deckmux: café" as CFString, &id)
        let pmset = SystemProcess.disableSleep(true)
        guard pmset.succeeded else {
            if created == kIOReturnSuccess { IOPMAssertionRelease(id) }
            Self.logger.error("pmset disablesleep 1 failed: \(pmset.output, privacy: .public)")
            throw Failure.denied(pmset.output.isEmpty ? "sudo recusou o comando (status \(pmset.status))" : pmset.output)
        }
        if created == kIOReturnSuccess { assertion = id }
        startWatcher()
        isEngaged = true
    }

    /// Idempotent. false when sleep could not be turned back on (the rule is gone).
    @discardableResult
    func release() -> Bool {
        guard isEngaged else { return true }
        let pmset = SystemProcess.disableSleep(false)
        if !pmset.succeeded { Self.logger.error("pmset disablesleep 0 failed: \(pmset.output, privacy: .public)") }
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
        watcher?.terminate()
        watcher = nil
        isEngaged = false
        return pmset.succeeded
    }

    /// At launch: a crash may have left sleep disabled, and the setting survives
    /// reboots. `done(false)` when sleep is still disabled and Deckmux cannot fix it.
    static func restoreSleepAtLaunch(_ done: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard isSleepDisabled() else { return }
            let restored = SudoersRule.isInstalled() && SystemProcess.disableSleep(false).succeeded
            DispatchQueue.main.async { MainActor.assumeIsolated { done(restored) } }
        }
    }

    /// `pmset -g` lists "SleepDisabled 1" while sleep is off.
    nonisolated static func isSleepDisabled() -> Bool {
        SystemCommands.sleepDisabled(pmsetOutput: SystemProcess.run("/usr/bin/pmset", ["-g"]).output)
    }

    /// A child process outlives Deckmux on macOS; it ignores SIGHUP and polls our PID.
    private func startWatcher() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SystemCommands.watcherScript, "deckmux-cafe", String(getpid())]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            watcher = process
        } catch {
            Self.logger.error("Could not start the café watcher: \(error, privacy: .public)")
        }
    }
}
