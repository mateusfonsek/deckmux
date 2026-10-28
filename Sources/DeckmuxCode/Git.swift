import Foundation

public enum GitError: Error, Equatable {
    case notFound
    case tooLarge(size: Int)
    case failed(code: Int32, message: String)
}

public enum CodeLimits {
    public static let maxBytes = 5_000_000
    public static let highlightBytes = 256 * 1024
    public static let highlightLines = 4_000
    public static let statusEntries = 10_000
}

/// Runs the `git` command line against one repository. `path` is the PATH given to the child process.
public struct Git: Sendable {
    public let root: URL
    public let path: String

    public init(root: URL, path: String) {
        self.root = root
        self.path = path
    }

    // MARK: Public API

    public static func toplevel(of folder: URL, path: String) async -> URL? {
        guard let out = try? await run(["-C", folder.path, "rev-parse", "--show-toplevel"], path: path, okCodes: [0]) else {
            return nil
        }
        var text = String(decoding: out, as: UTF8.self)
        while text.hasSuffix("\n") { text.removeLast() }
        return text.isEmpty ? nil : URL(fileURLWithPath: text, isDirectory: true)
    }

    public func status() async throws -> GitStatus {
        let out = try await run(["status", "-z", "--porcelain=v1", "-uall", "--find-renames"])
        return GitStatus.parse(out, limit: CodeLimits.statusEntries)
    }

    public func diff(_ change: FileChange) async throws -> UnifiedDiff {
        if change.group == .unstaged {
            let url = root.appendingPathComponent(change.path)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = (attrs[.size] as? NSNumber)?.intValue, size > CodeLimits.maxBytes {
                throw GitError.tooLarge(size: size)
            }
        } else if let size = try? await size(":" + change.path), size > CodeLimits.maxBytes {
            throw GitError.tooLarge(size: size)
        }
        if change.kind == .untracked {
            let url = root.appendingPathComponent(change.path)
            guard let data = try? Data(contentsOf: url) else { return UnifiedDiff(hunks: [], isBinary: false) }
            if data.prefix(8_000).contains(0) { return UnifiedDiff(hunks: [], isBinary: true) }
            return UnifiedDiff.allAdded(String(decoding: data, as: UTF8.self))
        }
        var args = ["diff"]
        // An unmerged file gets a combined diff (`@@@`) with no plain hunks;
        // against HEAD it is an ordinary diff that shows the markers.
        if change.kind == .conflict { args.append("HEAD") } else if change.group == .staged { args.append("--cached") }
        args += ["--no-color", "--no-ext-diff", "--find-renames", "-U999999", "--"]
        if let original = change.originalPath { args.append(original) }
        args.append(change.path)
        let out = try await run(args)
        return UnifiedDiff.parse(String(decoding: out, as: UTF8.self))
    }

    /// `spec` is `HEAD:<path>` or `:<path>`.
    public func show(_ spec: String) async throws -> Data {
        try await run(["show", spec])
    }

    /// The size in bytes of a blob; `spec` is `HEAD:<path>` or `:<path>`.
    public func size(_ spec: String) async throws -> Int {
        let out = try await run(["cat-file", "-s", spec])
        guard let size = Int(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw GitError.failed(code: 0, message: "cat-file -s")
        }
        return size
    }

    /// The paths `.gitignore` matches. Paths inside a nested repository (a
    /// submodule) are left out: git aborts the whole call on them
    /// ("Pathspec … is in submodule"), losing the answer for every other path.
    public func ignored(_ paths: [String]) async throws -> Set<String> {
        let paths = Self.outsideNestedRepositories(paths, root: root)
        if paths.isEmpty { return [] }
        var input = Data()
        for p in paths { input.append(Data(p.utf8)); input.append(0) }
        let out = try await run(["check-ignore", "-z", "--stdin"], stdin: input, okCodes: [0, 1])
        return Set(out.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) })
    }

    /// `paths` (relative to `root`) without those under a folder holding a
    /// `.git` (a submodule, or another repository inside this one).
    static func outsideNestedRepositories(_ paths: [String], root: URL) -> [String] {
        var known: [String: Bool] = [:]
        func isRepository(_ folder: String) -> Bool {
            if let value = known[folder] { return value }
            let value = FileManager.default.fileExists(atPath: root.appendingPathComponent(folder).appendingPathComponent(".git").path)
            known[folder] = value
            return value
        }
        return paths.filter { path in
            var folder = (path as NSString).deletingLastPathComponent
            while !folder.isEmpty, folder != "/" {
                if isRepository(folder) { return false }
                folder = (folder as NSString).deletingLastPathComponent
            }
            return true
        }
    }

    // MARK: Process

    private func run(_ args: [String], stdin: Data? = nil, okCodes: Set<Int32> = [0]) async throws -> Data {
        try await Git.run(["-C", root.path] + args, path: path, stdin: stdin, okCodes: okCodes)
    }

    private static func gitExists(in path: String) -> Bool {
        path.split(separator: ":").contains { dir in
            FileManager.default.isExecutableFile(atPath: String(dir) + "/git")
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
        func set(_ p: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            process = p
            return !cancelled
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if let p = process, p.isRunning { p.terminate() }
        }
    }

    private static func run(_ args: [String], path: String, stdin: Data? = nil, okCodes: Set<Int32>) async throws -> Data {
        guard gitExists(in: path) else { throw GitError.notFound }
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = ["git"] + args
                    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
                    env["PATH"] = path
                    env["GIT_OPTIONAL_LOCKS"] = "0"
                    env["LC_ALL"] = "C"
                    process.environment = env
                    let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = errPipe
                    process.standardInput = inPipe
                    do {
                        try process.run()
                    } catch {
                        cont.resume(throwing: GitError.failed(code: -1, message: "\(error)"))
                        return
                    }
                    if !box.set(process) { process.terminate() }
                    // Drain stderr and feed stdin on side threads so no pipe fills up and blocks git.
                    let group = DispatchGroup()
                    var errData = Data()
                    group.enter()
                    DispatchQueue.global().async {
                        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global().async {
                        // git may exit before reading all of stdin (an error):
                        // the write then fails with EPIPE instead of raising
                        // SIGPIPE, which would kill the app.
                        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                        if let stdin { try? inPipe.fileHandleForWriting.write(contentsOf: stdin) }
                        try? inPipe.fileHandleForWriting.close()
                        group.leave()
                    }
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()
                    if box.isCancelled {
                        cont.resume(throwing: CancellationError())
                    } else if okCodes.contains(process.terminationStatus) {
                        cont.resume(returning: outData)
                    } else {
                        let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        cont.resume(throwing: GitError.failed(code: process.terminationStatus, message: message))
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}
