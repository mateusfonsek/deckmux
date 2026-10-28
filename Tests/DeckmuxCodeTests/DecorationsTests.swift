import Foundation
import Testing
@testable import DeckmuxCode

@Test func fileShowsWorktreeKindFirst() {
    let d = Decorations(GitStatus.parse(Data("MM a.swift\0A  b.swift\0".utf8)))
    #expect(d.kind(ofFile: "a.swift") == .modified)
    #expect(d.kind(ofFile: "b.swift") == .added)
    #expect(d.kind(ofFile: "c.swift") == nil)
}
@Test func folderInheritsChildrenExceptDeletions() {
    let d = Decorations(GitStatus.parse(Data(" D src/old.swift\0?? src/ui/new.swift\0 M src/ui/view.swift\0".utf8)))
    #expect(d.kind(ofFolder: "src") == .modified)        // modified beats untracked
    #expect(d.kind(ofFolder: "src/ui") == .modified)
    let onlyDeleted = Decorations(GitStatus.parse(Data(" D gone/a.swift\0".utf8)))
    #expect(onlyDeleted.kind(ofFolder: "gone") == nil)
}
@Test func conflictWinsInFolders() {
    let d = Decorations(GitStatus.parse(Data(" M a/x.swift\0UU a/y.swift\0".utf8)))
    #expect(d.kind(ofFolder: "a") == .conflict)
}
@Test func decorationsMatchDecomposedPaths() {
    let d = Decorations(GitStatus.parse(Data(" M relatório.md\0".utf8)))           // NFC from git
    #expect(d.kind(ofFile: "relato\u{0301}rio.md") == .modified)                 // NFD from the file system
}
