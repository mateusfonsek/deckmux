import Foundation

/// A line diff for the review sheet, with unchanged runs folded around the
/// changes.
enum LineDiff {
    enum Line: Equatable {
        case same(String)
        case added(String)
        case removed(String)
        /// Unchanged lines not shown.
        case folded(Int)
    }

    static func lines(from old: String?, to new: String?, context: Int = 3) -> [Line] {
        let a = split(old)
        let b = split(new)
        let difference = b.difference(from: a)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Walk both sides in order, emitting removals before insertions.
        var full: [Line] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                full.append(.removed(a[i])); i += 1
            } else if j < b.count, inserted.contains(j) {
                full.append(.added(b[j])); j += 1
            } else if i < a.count, j < b.count {
                full.append(.same(a[i])); i += 1; j += 1
            } else if i < a.count {
                full.append(.removed(a[i])); i += 1
            } else {
                full.append(.added(b[j])); j += 1
            }
        }
        return fold(full, context: context)
    }

    private static func split(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func fold(_ lines: [Line], context: Int) -> [Line] {
        let changed = lines.indices.filter { if case .same = lines[$0] { false } else { true } }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for index in changed {
            for k in max(0, index - context)...min(lines.count - 1, index + context) { keep.insert(k) }
        }
        var out: [Line] = []
        var hidden = 0
        for index in lines.indices {
            if keep.contains(index) {
                if hidden > 0 { out.append(.folded(hidden)); hidden = 0 }
                out.append(lines[index])
            } else {
                hidden += 1
            }
        }
        if hidden > 0 { out.append(.folded(hidden)) }
        return out
    }

    /// Text form, for logs and tests.
    static func unified(from old: String?, to new: String?) -> String {
        lines(from: old, to: new).map { line in
            switch line {
            case .same(let text): "  " + text
            case .added(let text): "+ " + text
            case .removed(let text): "- " + text
            case .folded(let count): "  … \(count) linhas iguais"
            }
        }.joined(separator: "\n")
    }
}
