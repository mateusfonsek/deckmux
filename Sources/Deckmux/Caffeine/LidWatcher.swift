import DeckmuxCaffeine
import Foundation
import IOKit
import OSLog

/// Tells when the lid closes, from IOPMrootDomain's clamshell messages: no
/// polling, nothing runs until the lid moves.
@MainActor
final class LidWatcher {
    nonisolated private static let logger = Logger(subsystem: "dev.fonsek.deckmux", category: "cafe")

    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var onClose: (() -> Void)?

    func start(onClose: @escaping () -> Void) {
        guard port == nil else { return }
        self.onClose = onClose
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            Self.logger.error("Could not watch the lid")
            return
        }
        defer { IOObjectRelease(rootDomain) }
        IONotificationPortSetDispatchQueue(port, .main)
        let result = IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest, { refcon, _, message, argument in
            guard let refcon, Lid.isClosed(message: message, argument: UInt(bitPattern: argument)) == true else { return }
            let watcher = Unmanaged<LidWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onClose?() }
        }, Unmanaged.passUnretained(self).toOpaque(), &notifier)
        guard result == KERN_SUCCESS else {
            Self.logger.error("Could not watch the lid: \(result)")
            IONotificationPortDestroy(port)
            return
        }
        self.port = port
    }

    func stop() {
        if notifier != 0 { IOObjectRelease(notifier) }
        notifier = 0
        if let port { IONotificationPortDestroy(port) }
        port = nil
        onClose = nil
    }
}
