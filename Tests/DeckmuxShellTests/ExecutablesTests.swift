import Foundation
import Testing
@testable import DeckmuxShell

/// A throwaway folder tree: `make(["a/claude": true])` creates an executable.
private struct Tree {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("deckmux-exec-\(UUID().uuidString)")

    func file(_ relative: String, executable: Bool) {
        let url = root.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: executable ? 0o755 : 0o644])
    }

    func folder(_ relative: String) {
        try! FileManager.default.createDirectory(at: root.appendingPathComponent(relative), withIntermediateDirectories: true)
    }

    func path(_ dirs: String...) -> String { dirs.map { root.appendingPathComponent($0).path }.joined(separator: ":") }
}

@Test func findsFirstInPathOrder() {
    let tree = Tree()
    tree.file("a/claude", executable: true)
    tree.file("b/claude", executable: true)
    #expect(Executables.find("claude", inPath: tree.path("b", "a")) == tree.root.appendingPathComponent("b/claude").path)
}

/// No Claude Code installed: nothing found, so the app can explain it.
@Test func missingIsNil() {
    let tree = Tree()
    tree.folder("a")
    #expect(Executables.find("claude", inPath: tree.path("a")) == nil)
    #expect(Executables.find("claude", inPath: "") == nil)
}

@Test func skipsTheWrapperFolder() {
    let tree = Tree()
    tree.file("wrapper/claude", executable: true)
    tree.file("real/claude", executable: true)
    let found = Executables.find("claude", inPath: tree.path("wrapper", "real"),
                                 skipping: tree.root.appendingPathComponent("wrapper/").path)
    #expect(found == tree.root.appendingPathComponent("real/claude").path)
}

@Test func skipsNonExecutablesAndFolders() {
    let tree = Tree()
    tree.file("a/claude", executable: false)
    tree.folder("b/claude")
    tree.file("c/claude", executable: true)
    #expect(Executables.find("claude", inPath: tree.path("a", "b", "c")) == tree.root.appendingPathComponent("c/claude").path)
}
