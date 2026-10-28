import Foundation
import Testing
@testable import DeckmuxCode

@Test func parsesStagedAndUnstaged() {
    let s = GitStatus.parse(Data("M  a.swift\0 M b.swift\0MM c.swift\0?? novo.md\0A  d.swift\0 D e.swift\0".utf8))
    #expect(s.staged == [.init(path: "a.swift", originalPath: nil, kind: .modified, group: .staged),
                         .init(path: "c.swift", originalPath: nil, kind: .modified, group: .staged),
                         .init(path: "d.swift", originalPath: nil, kind: .added, group: .staged)])
    #expect(s.unstaged.map(\.path) == ["b.swift", "c.swift", "novo.md", "e.swift"])
    #expect(s.unstaged.map(\.kind) == [.modified, .modified, .untracked, .deleted])
}
@Test func parsesRenameWithOriginalPath() {
    // -z: "R  new\0old\0"
    let s = GitStatus.parse(Data("R  Sources/Novo.swift\0Sources/Velho.swift\0".utf8))
    #expect(s.staged == [.init(path: "Sources/Novo.swift", originalPath: "Sources/Velho.swift", kind: .renamed, group: .staged)])
}
@Test func conflictsGoToUnstagedOnly() {
    for xy in ["UU", "AA", "DD", "AU", "UA", "DU", "UD"] {
        let s = GitStatus.parse(Data("\(xy) x.swift\0".utf8))
        #expect(s.staged.isEmpty)
        #expect(s.unstaged == [.init(path: "x.swift", originalPath: nil, kind: .conflict, group: .unstaged)])
    }
}
@Test func keepsSpacesAndAccents() {
    let s = GitStatus.parse(Data(" M Documentos/relatório final.md\0".utf8))
    #expect(s.unstaged.first?.path == "Documentos/relatório final.md")
}
@Test func intentToAddIsAdded() {
    #expect(GitStatus.parse(Data(" A x.swift\0".utf8)).unstaged.first?.kind == .added)
}
@Test func truncatesAtLimit() {
    let data = Data((0..<12_000).map { "?? build/f\($0)\0" }.joined().utf8)
    let s = GitStatus.parse(data, limit: 10_000)
    #expect(s.staged.count + s.unstaged.count == 10_000)
    #expect(s.truncated)
}
