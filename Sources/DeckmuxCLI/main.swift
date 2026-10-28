// deckmux: the command-line side of Deckmux, run inside its terminals.
//
//   deckmux hook <event>   Forwards a Claude Code hook (its JSON on stdin) to
//                          the Deckmux app over its Unix socket.
//   deckmux task …         The task board of the Hoje screen (see TaskCommand.swift).
//
// Hooks must never slow Claude Code down or break it: every failure is silent
// and the command always exits 0 without printing anything.
import Darwin
import Foundation

let arguments = CommandLine.arguments.dropFirst()

if arguments.first == "task" {
    exit(TaskCommand.run(Array(arguments.dropFirst())))
}

guard arguments.first == "hook", let event = arguments.dropFirst().first else {
    FileHandle.standardError.write(Data("usage: deckmux hook <event> | deckmux task --help\n".utf8))
    exit(arguments.isEmpty ? 0 : 2)
}

let environment = ProcessInfo.processInfo.environment
let stdinData = isatty(STDIN_FILENO) == 0 ? FileHandle.standardInput.readDataToEndOfFile() : Data()

guard let surface = environment["DECKMUX_SURFACE_ID"], !surface.isEmpty,
      let socketPath = environment["DECKMUX_SOCKET_PATH"], !socketPath.isEmpty else { exit(0) }

let payload = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any] ?? [:]
let message: [String: Any] = ["event": event, "surface": surface, "payload": payload]
guard let body = try? JSONSerialization.data(withJSONObject: message) else { exit(0) }

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
var timeout = timeval(tv_sec: 1, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, [Int32(1)], socklen_t(MemoryLayout<Int32>.size))

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { exit(0) }
withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    buffer.copyBytes(from: socketPath.utf8)
    buffer[socketPath.utf8.count] = 0
}
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { exit(0) }
body.withUnsafeBytes { buffer in
    var offset = 0
    while offset < buffer.count {
        let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
        guard written > 0 else { break }
        offset += written
    }
}
shutdown(fd, SHUT_WR)
close(fd)
exit(0)
