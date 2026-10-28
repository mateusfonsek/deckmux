import Foundation

public enum IntralineDiff {
    /// Lines longer than this (in UTF-16 units) are not compared.
    static let maxLength = 1_000

    /// Character ranges (UTF-16) that differ between the two lines.
    public static func ranges(old: String, new: String) -> (old: [NSRange], new: [NSRange]) {
        let a = Array(old.utf16), b = Array(new.utf16)
        guard a.count <= maxLength, b.count <= maxLength else { return ([], []) }
        let diff = b.difference(from: a)
        var removed: [Int] = [], inserted: [Int] = []
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.append(offset)
            case .insert(let offset, _, _): inserted.append(offset)
            }
        }
        return (merge(removed), merge(inserted))
    }

    private static func merge(_ offsets: [Int]) -> [NSRange] {
        var out: [NSRange] = []
        for o in offsets.sorted() {
            if let last = out.last, last.location + last.length == o {
                out[out.count - 1].length += 1
            } else {
                out.append(NSRange(location: o, length: 1))
            }
        }
        return out
    }
}
