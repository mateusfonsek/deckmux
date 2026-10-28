import Foundation

public struct NumberedLine: Equatable, Sendable {
    public var number: Int
    public var text: String
    /// UTF-16 ranges of the characters that differ from the paired line.
    public var changed: [NSRange]

    public init(number: Int, text: String, changed: [NSRange] = []) {
        self.number = number
        self.text = text
        self.changed = changed
    }
}

public enum DiffBlock: Equatable, Sendable {
    case context(old: [NumberedLine], new: [NumberedLine])
    case change(removed: [NumberedLine], added: [NumberedLine])
    /// Hidden unchanged lines; kept so a click can expand them.
    case fold(old: [NumberedLine], new: [NumberedLine])
}

public enum DiffBlocks {
    /// Unchanged runs keep `context` lines next to each change and fold the
    /// rest, but only when at least `minFold` lines would hide: folding two
    /// lines saves nothing and costs a click.
    public static func make(_ diff: UnifiedDiff, context: Int = 3, minFold: Int = 4) -> [DiffBlock] {
        (try? make(diff, context: context, minFold: minFold, check: {})) ?? []
    }

    /// `make`, checking `Task.isCancelled` as it goes (a long diff takes a
    /// while); throws `CancellationError` when the task was cancelled.
    public static func makeCancellable(_ diff: UnifiedDiff, context: Int = 3, minFold: Int = 4) throws -> [DiffBlock] {
        try make(diff, context: context, minFold: minFold, check: { try Task.checkCancellation() })
    }

    /// Lines handled between two cancellation checks.
    static let checkEvery = 256

    private static func make(_ diff: UnifiedDiff, context: Int, minFold: Int, check: () throws -> Void) throws -> [DiffBlock] {
        var blocks: [DiffBlock] = []
        try check()
        for hunk in diff.hunks { blocks += try make(hunk, context: context, minFold: minFold, check: check) }
        return blocks
    }

    private enum Segment {
        case context([(old: NumberedLine, new: NumberedLine)])
        case change(removed: [NumberedLine], added: [NumberedLine])
    }

    private static func make(_ hunk: Hunk, context: Int, minFold: Int, check: () throws -> Void) throws -> [DiffBlock] {
        var counter = 0
        func tick() throws {
            counter += 1
            if counter % checkEvery == 0 { try check() }
        }
        var oldNo = hunk.oldStart, newNo = hunk.newStart
        var segments: [Segment] = []
        var ctx: [(old: NumberedLine, new: NumberedLine)] = []
        var removed: [NumberedLine] = [], added: [NumberedLine] = []

        func flushContext() {
            if !ctx.isEmpty { segments.append(.context(ctx)); ctx = [] }
        }
        func flushChange() throws {
            guard !removed.isEmpty || !added.isEmpty else { return }
            for i in 0..<min(removed.count, added.count) {
                try tick()
                let r = IntralineDiff.ranges(old: removed[i].text, new: added[i].text)
                removed[i].changed = r.old
                added[i].changed = r.new
            }
            segments.append(.change(removed: removed, added: added))
            removed = []; added = []
        }

        for line in hunk.lines {
            try tick()
            switch line {
            case .context(let t):
                try flushChange()
                ctx.append((NumberedLine(number: oldNo, text: t), NumberedLine(number: newNo, text: t)))
                oldNo += 1; newNo += 1
            case .removed(let t):
                flushContext()
                removed.append(NumberedLine(number: oldNo, text: t)); oldNo += 1
            case .added(let t):
                flushContext()
                added.append(NumberedLine(number: newNo, text: t)); newNo += 1
            }
        }
        flushContext(); try flushChange()

        var blocks: [DiffBlock] = []
        for (i, segment) in segments.enumerated() {
            switch segment {
            case .change(let r, let a):
                blocks.append(.change(removed: r, added: a))
            case .context(let pairs):
                let hasPrev = i > 0, hasNext = i + 1 < segments.count
                let lead = hasPrev ? context : 0, trail = hasNext ? context : 0
                func emit(_ slice: ArraySlice<(old: NumberedLine, new: NumberedLine)>, fold: Bool) {
                    guard !slice.isEmpty else { return }
                    let o = slice.map(\.old), n = slice.map(\.new)
                    blocks.append(fold ? .fold(old: o, new: n) : .context(old: o, new: n))
                }
                if pairs.count - lead - trail >= max(1, minFold) {
                    emit(pairs[..<lead], fold: false)
                    emit(pairs[lead..<(pairs.count - trail)], fold: true)
                    emit(pairs[(pairs.count - trail)...], fold: false)
                } else {
                    emit(pairs[...], fold: false)
                }
            }
        }
        return blocks
    }
}
