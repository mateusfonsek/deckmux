import Foundation
import Testing
@testable import DeckmuxCode

@discardableResult
func runGit(_ args: [String], in dir: URL) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["git", "-C", dir.path] + args
    var env = ProcessInfo.processInfo.environment
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Temp repo with a.txt committed ("um\ndois\n"). Lives under the system temp dir.
func makeRepo() throws -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("deckmux-git-\(UUID().uuidString)")
    let repo = base.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try runGit(["init", "-q", "-b", "main"], in: repo)
    try runGit(["config", "user.name", "Teste"], in: repo)
    try runGit(["config", "user.email", "teste@example.com"], in: repo)
    try runGit(["config", "commit.gpgsign", "false"], in: repo)
    try "um\ndois\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try runGit(["add", "a.txt"], in: repo)
    try runGit(["commit", "-q", "-m", "inicial"], in: repo)
    return repo
}

private func cleanup(_ repo: URL) { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }

@Test func statusAndDiffOfARealRepo() async throws {
    let repo = try makeRepo(); defer { cleanup(repo) }
    try "um\nDOIS\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "novo\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    let git = Git(root: repo, path: "/usr/bin:/bin:/opt/homebrew/bin")
    let status = try await git.status()
    #expect(status.unstaged.map(\.path).sorted() == ["a.txt", "b.txt"])
    let diff = try await git.diff(status.unstaged.first { $0.path == "a.txt" }!)
    #expect(diff.hunks.first?.lines.contains(.added("DOIS")) == true)
    let untracked = try await git.diff(status.unstaged.first { $0.path == "b.txt" }!)
    #expect(untracked == UnifiedDiff.allAdded("novo\n"))
    #expect(try await git.show("HEAD:a.txt") == Data("um\ndois\n".utf8))
}

@Test func stagedAndRenamedDiff() async throws {
    let repo = try makeRepo(); defer { cleanup(repo) }
    try runGit(["mv", "a.txt", "c.txt"], in: repo)
    let git = Git(root: repo, path: "/usr/bin:/bin:/opt/homebrew/bin")
    let status = try await git.status()
    let change = try #require(status.staged.first)
    #expect(change.kind == .renamed)
    let diff = try await git.diff(change)
    #expect(diff.hunks.isEmpty && !diff.isBinary)  // pure rename: no content change
}

@Test func toplevelFromSubfolder() async throws {
    let repo = try makeRepo(); defer { cleanup(repo) }
    let sub = repo.appendingPathComponent("x/y")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    #expect(await Git.toplevel(of: sub, path: "/usr/bin:/bin")?.resolvingSymlinksInPath() == repo.resolvingSymlinksInPath())
    #expect(await Git.toplevel(of: FileManager.default.temporaryDirectory, path: "/usr/bin:/bin") == nil)
}

@Test func toplevelInWorktree() async throws {
    let repo = try makeRepo(); defer { cleanup(repo) }
    let wt = repo.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try runGit(["worktree", "add", wt.path], in: repo)
    #expect(await Git.toplevel(of: wt, path: "/usr/bin:/bin")?.resolvingSymlinksInPath() == wt.resolvingSymlinksInPath())
}

@Test func ignoredPaths() async throws {
    let repo = try makeRepo(); defer { cleanup(repo) }
    try "build/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent("build"), withIntermediateDirectories: true)
    #expect(try await Git(root: repo, path: "/usr/bin:/bin").ignored(["build", "a.txt"]) == ["build"])
    #expect(try await Git(root: repo, path: "/usr/bin:/bin").ignored(["a.txt"]) == [])
}

@Test func missingGitIsNotFound() async {
    do {
        _ = try await Git(root: URL(fileURLWithPath: "/"), path: "/nonexistent").status()
        Issue.record("expected GitError.notFound")
    } catch {
        #expect(error as? GitError == .notFound)
    }
}

@Test func hugeUntrackedFileIsTooLarge() async throws {
    let repo = try makeRepo(); defer { cleanup(repo) }
    let url = repo.appendingPathComponent("huge.txt")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(CodeLimits.maxBytes + 1))
    try handle.close()
    let git = Git(root: repo, path: "/usr/bin:/bin")
    let change = FileChange(path: "huge.txt", originalPath: nil, kind: .untracked, group: .unstaged)
    await #expect(throws: GitError.tooLarge(size: CodeLimits.maxBytes + 1)) { try await git.diff(change) }
}

@Test func cancellationThrowsCancellationError() async throws {
    let repo = try makeRepo(); defer { cleanup(repo) }
    // A fake `git` that sleeps, so the call is still running when we cancel.
    let bin = repo.deletingLastPathComponent().appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let script = bin.appendingPathComponent("git")
    try "#!/bin/sh\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let git = Git(root: repo, path: bin.path + ":/usr/bin:/bin")
    let task = Task { try await git.status() }
    try await Task.sleep(nanoseconds: 300_000_000)
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("expected cancellation")
    } catch {
        #expect(error is CancellationError)
    }
}

@Test func conflictDiffShowsMarkers() async throws {
    let repo = try makeRepo(); defer { cleanup(repo) }
    try runGit(["checkout", "-q", "-b", "outro"], in: repo)
    try "um\nOUTRO\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try runGit(["commit", "-q", "-am", "outro"], in: repo)
    try runGit(["checkout", "-q", "main"], in: repo)
    try "um\nMAIN\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try runGit(["commit", "-q", "-am", "main"], in: repo)
    try runGit(["merge", "-q", "outro"], in: repo)
    let git = Git(root: repo, path: "/usr/bin:/bin:/opt/homebrew/bin")
    let change = try #require(try await git.status().unstaged.first)
    #expect(change.kind == .conflict)
    let lines = try await git.diff(change).hunks.flatMap(\.lines)
    #expect(lines.contains(.added("<<<<<<< HEAD")))
    #expect(lines.contains(.added(">>>>>>> outro")))
}

@Test func ignoredSkipsPathsInsideASubmodule() async throws {
    let repo = try makeRepo(); defer { cleanup(repo) }
    let other = try makeRepo(); defer { cleanup(other) }
    try runGit(["-c", "protocol.file.allow=always", "submodule", "add", "-q", other.path, "sub"], in: repo)
    try "build/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent("build"), withIntermediateDirectories: true)
    #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("sub/a.txt").path))
    let git = Git(root: repo, path: "/usr/bin:/bin:/opt/homebrew/bin")
    // git alone aborts on "sub/a.txt" (in submodule 'sub'), losing "build".
    #expect(try await git.ignored(["build", "sub", "sub/a.txt", "a.txt"]) == ["build"])
}

@Test func ignoredSurvivesGitExitingBeforeReadingALargeInput() async throws {
    let repo = try makeRepo(); defer { cleanup(repo) }
    // A fake `git` that exits at once: writing ~2 MB to its stdin hits a closed pipe.
    let bin = repo.deletingLastPathComponent().appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let script = bin.appendingPathComponent("git")
    try "#!/bin/sh\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let paths = (0..<40_000).map { "pasta/arquivo-\($0)-com-um-nome-longo.txt" }
    let found = try await Git(root: repo, path: bin.path + ":/usr/bin:/bin").ignored(paths)
    #expect(found.isEmpty)
}

@Test func objectSizes() async throws {
    let repo = try makeRepo(); defer { cleanup(repo) }
    let git = Git(root: repo, path: "/usr/bin:/bin:/opt/homebrew/bin")
    #expect(try await git.size("HEAD:a.txt") == 8)
    #expect(try await git.size(":a.txt") == 8)
    await #expect(throws: GitError.self) { try await git.size("HEAD:nada.txt") }
}

/// The app tells "not a repository" (stop asking) from a passing failure by this message.
@Test func notARepositoryIsCode128WithItsMessage() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckmux-plain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    do {
        _ = try await Git(root: dir, path: "/usr/bin:/bin:/opt/homebrew/bin").status()
        Issue.record("expected a failure")
    } catch GitError.failed(let code, let message) {
        #expect(code == 128)
        #expect(message.contains("not a git repository"))
    }
}
