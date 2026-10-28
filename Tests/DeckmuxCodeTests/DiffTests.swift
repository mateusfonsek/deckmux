import Foundation
import Testing
@testable import DeckmuxCode

private let sample = """
diff --git a/x.swift b/x.swift
index 1111111..2222222 100644
--- a/x.swift
+++ b/x.swift
@@ -1,4 +1,4 @@
 um
-dois
+DOIS
 tres
 quatro
\\ No newline at end of file
"""

@Test func parsesHunks() {
    let d = UnifiedDiff.parse(sample)
    #expect(d.hunks == [Hunk(oldStart: 1, newStart: 1, lines: [.context("um"), .removed("dois"), .added("DOIS"), .context("tres"), .context("quatro")])])
    #expect(!d.isBinary)
}
@Test func detectsBinary() {
    #expect(UnifiedDiff.parse("diff --git a/i.png b/i.png\nBinary files a/i.png and b/i.png differ\n").isBinary)
}
@Test func untrackedIsAllAdded() {
    #expect(UnifiedDiff.allAdded("a\nb\n").hunks == [Hunk(oldStart: 0, newStart: 1, lines: [.added("a"), .added("b")])])
}
@Test func blocksNumberBothSides() {
    let b = DiffBlocks.make(UnifiedDiff.parse(sample))
    guard case .change(let removed, let added) = b[1] else { Issue.record("expected change"); return }
    #expect(removed.map(\.number) == [2]); #expect(added.map(\.number) == [2])
}
@Test func foldsLongUnchangedRunsKeepingThreeLinesOfContext() {
    let lines = (1...30).map { DiffLine.context("l\($0)") } + [.removed("x"), .added("y")]
    let b = DiffBlocks.make(UnifiedDiff(hunks: [Hunk(oldStart: 1, newStart: 1, lines: lines)], isBinary: false))
    guard case .fold(let old, _) = b[0], case .context(let ctx, _) = b[1] else { Issue.record("expected fold then context"); return }
    #expect(old.count == 27); #expect(ctx.map(\.number) == [28, 29, 30])
}
@Test func shortRunsAreNotFolded() {
    let lines = (1...6).map { DiffLine.context("l\($0)") } + [.added("y")]
    let b = DiffBlocks.make(UnifiedDiff(hunks: [Hunk(oldStart: 1, newStart: 1, lines: lines)], isBinary: false))
    #expect(!b.contains { if case .fold = $0 { true } else { false } })
}
@Test func intralineMarksOnlyTheChangedCharacters() {
    let r = IntralineDiff.ranges(old: "let total = 10", new: "let total = 25")
    #expect(r.old == [NSRange(location: 12, length: 2)]); #expect(r.new == [NSRange(location: 12, length: 2)])
}
@Test func intralineSkipsVeryLongLines() {
    let long = String(repeating: "a", count: 2_000)
    #expect(IntralineDiff.ranges(old: long, new: long + "b") == ([], []))
}

@Test func parsesCRLFDiff() {
    let text = "diff --git a/x b/x\r\n--- a/x\r\n+++ b/x\r\n@@ -1,2 +1,2 @@\r\n um\r\n-dois\r\n+DOIS\r\n"
    #expect(UnifiedDiff.parse(text).hunks == [Hunk(oldStart: 1, newStart: 1, lines: [.context("um"), .removed("dois"), .added("DOIS")])])
}
@Test func allAddedHandlesCRLF() {
    #expect(UnifiedDiff.allAdded("a\r\nb\r\n").hunks == [Hunk(oldStart: 0, newStart: 1, lines: [.added("a"), .added("b")])])
}
@Test func foldBetweenTwoChanges() {
    let mid = (1...20).map { DiffLine.context("m\($0)") }
    let lines: [DiffLine] = [.removed("a"), .added("b")] + mid + [.removed("c"), .added("d")]
    let b = DiffBlocks.make(UnifiedDiff(hunks: [Hunk(oldStart: 1, newStart: 1, lines: lines)], isBinary: false))
    #expect(b.count == 5)
    guard case .context(let lo, let ln) = b[1], case .fold(let fo, let fn) = b[2], case .context(let to, let tn) = b[3] else {
        Issue.record("expected context, fold, context"); return
    }
    #expect(lo.map(\.number) == [2, 3, 4]); #expect(ln.map(\.number) == [2, 3, 4])
    #expect(fo.count == 14); #expect(fo.first?.number == 5); #expect(fn.first?.number == 5); #expect(fn.last?.number == 18)
    #expect(to.map(\.number) == [19, 20, 21]); #expect(tn.map(\.number) == [19, 20, 21])
    guard case .change(let r, let a) = b[4] else { Issue.record("expected change"); return }
    #expect(r.map(\.number) == [22]); #expect(a.map(\.number) == [22])
}

private func contextBetweenTwoChanges(_ count: Int) -> [DiffBlock] {
    let mid = (1...count).map { DiffLine.context("m\($0)") }
    let lines: [DiffLine] = [.removed("a"), .added("b")] + mid + [.removed("c"), .added("d")]
    return DiffBlocks.make(UnifiedDiff(hunks: [Hunk(oldStart: 1, newStart: 1, lines: lines)], isBinary: false))
}
private func folded(_ blocks: [DiffBlock]) -> [Int] {
    blocks.compactMap { if case .fold(let old, _) = $0 { old.count } else { nil } }
}
@Test func foldsOnlyWhenFourOrMoreLinesWouldHide() {
    // 3 lines of context kept on each side: 8 between two changes would hide 2.
    #expect(folded(contextBetweenTwoChanges(8)) == [])
    #expect(folded(contextBetweenTwoChanges(9)) == [])
    #expect(folded(contextBetweenTwoChanges(10)) == [4])
    // Before the first change only 3 lines stay: 7 lines hide 4.
    let lines = (1...7).map { DiffLine.context("l\($0)") } + [.added("y")]
    let b = DiffBlocks.make(UnifiedDiff(hunks: [Hunk(oldStart: 1, newStart: 1, lines: lines)], isBinary: false))
    #expect(folded(b) == [4])
}
@Test func cancelledBlockBuildingThrows() async throws {
    let lines = (1...5_000).flatMap { [DiffLine.removed("a\($0)"), .added("b\($0)")] }
    let diff = UnifiedDiff(hunks: [Hunk(oldStart: 1, newStart: 1, lines: lines)], isBinary: false)
    let result = await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try DiffBlocks.makeCancellable(diff)
    }.result
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(try DiffBlocks.makeCancellable(diff).count == 1)
}
