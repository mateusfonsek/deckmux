import Darwin
import Foundation
import OSLog

/// A message from `deckmux hook <event>`: which terminal it came from and the
/// JSON Claude Code gave the hook on stdin.
struct AgentHookMessage: Decodable {
    let event: String
    let surface: String
    let payload: [String: HookValue]

    var terminalID: UUID? { UUID(uuidString: surface) }

    func string(_ key: String) -> String? {
        if case .string(let value)? = payload[key] { return value }
        return nil
    }
}

/// The parts of a JSON document the hooks need.
enum HookValue: Decodable {
    case string(String)
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = (try? container.decode(String.self)).map(HookValue.string) ?? .other
    }
}

/// Listens on a Unix socket for hook messages, one JSON document per
/// connection, and hands each to `onMessage` on the main thread.
final class AgentSocketServer {
    private static let logger = Logger(subsystem: "dev.fonsek.deckmux", category: "agent")
    private static let maxMessageBytes = 1 << 20

    let path: String
    var onMessage: ((AgentHookMessage) -> Void)?

    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dev.fonsek.deckmux.agent-socket")

    init(path: String) {
        self.path = path
    }

    deinit { stop() }

    func start() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // A socket left by a previous run that did not exit cleanly.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return Self.logger.error("socket() failed: \(errno)") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            close(fd)
            return Self.logger.error("Socket path too long: \(self.path, privacy: .public)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            return Self.logger.error("Could not listen on \(self.path, privacy: .public): \(errno)")
        }
        // Only this user can send hook messages.
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
            unlink(path)
        }
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            handle(client)
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        // Accepted sockets inherit O_NONBLOCK from the listener on BSD.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        // The client writes its message and closes; never wait on it for long.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count < Self.maxMessageBytes {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        guard let message = try? JSONDecoder().decode(AgentHookMessage.self, from: data) else {
            return Self.logger.error("Ignoring malformed hook message (\(data.count) bytes)")
        }
        DispatchQueue.main.async { [weak self] in self?.onMessage?(message) }
    }
}
