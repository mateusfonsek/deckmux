import AppKit
import DeckmuxCode

/// One text view's worth of a diff: the text, a number per line and what is
/// laid over it. Every line ends in "\n", so line `i` of the text is
/// `lineNumbers[i]`.
struct RenderedSide: @unchecked Sendable {
    var text = ""
    var lineNumbers: [Int?] = []
    /// Full-width line backgrounds (removed, added, alignment and folded lines).
    var backgrounds: [(NSRange, NSColor)] = []
    /// The characters that changed inside a line, in a stronger tone.
    var spans: [(NSRange, NSColor)] = []
    /// The "⋯ n linhas sem mudança" lines; `index` is the `.fold` in the blocks.
    var folds: [(NSRange, index: Int)] = []
    /// The first line (0-based) of each `.change` block, for ↑ and ↓.
    var changeLines: [Int] = []
    /// The blocks' version, carried in the fold links.
    var version = 0

    var overlay: CodeTextView.Overlay {
        CodeTextView.Overlay(lineNumbers: lineNumbers, lineBackgrounds: backgrounds, spanBackgrounds: spans,
                             links: folds.compactMap { fold in DiffRendering.foldURL(fold.index, version: version).map { (fold.0, $0) } })
    }
}

/// Lays out `DiffBlocks` for the diff view: side by side, the
/// two sides aligned line for line, or inline, removed before added.
enum DiffRendering {
    static let removedLine = NSColor.systemRed.withAlphaComponent(0.12)
    static let addedLine = NSColor.systemGreen.withAlphaComponent(0.12)
    static let removedChars = NSColor.systemRed.withAlphaComponent(0.30)
    static let addedChars = NSColor.systemGreen.withAlphaComponent(0.30)
    /// The empty lines that keep the sides aligned, and the folded lines.
    static let neutralLine = NSColor.labelColor.withAlphaComponent(0.04)

    static let foldScheme = "deckmux-fold"

    static func foldText(_ count: Int) -> String { "⋯ \(count) linhas sem mudança" }
    /// `deckmux-fold:<index>/<version>`.
    static func foldURL(_ index: Int, version: Int) -> URL? { URL(string: "\(foldScheme):\(index)/\(version)") }
    static func fold(_ link: Any) -> (index: Int, version: Int)? {
        let text = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        guard text.hasPrefix(foldScheme + ":") else { return nil }
        let parts = text.dropFirst(foldScheme.count + 1).split(separator: "/")
        guard parts.count == 2, let index = Int(parts[0]), let version = Int(parts[1]) else { return nil }
        return (index, version)
    }

    static func sideBySide(_ blocks: [DiffBlock], version: Int = 0) -> (left: RenderedSide, right: RenderedSide) {
        var left = Builder(), right = Builder()
        left.side.version = version
        right.side.version = version
        for (index, block) in blocks.enumerated() {
            switch block {
            case .context(let old, let new):
                for (o, n) in zip(old, new) {
                    left.line(o.text, number: o.number)
                    right.line(n.text, number: n.number)
                }
            case .fold(let old, _):
                left.fold(old.count, index: index)
                right.fold(old.count, index: index)
            case .change(let removed, let added):
                left.markChange()
                right.markChange()
                for i in 0..<max(removed.count, added.count) {
                    if i < removed.count {
                        left.line(removed[i].text, number: removed[i].number, background: removedLine,
                                  changed: removed[i].changed, changedColor: removedChars)
                    } else {
                        left.line("", number: nil, background: neutralLine)
                    }
                    if i < added.count {
                        right.line(added[i].text, number: added[i].number, background: addedLine,
                                   changed: added[i].changed, changedColor: addedChars)
                    } else {
                        right.line("", number: nil, background: neutralLine)
                    }
                }
            }
        }
        return (left.side, right.side)
    }

    /// One column: the ruler shows the new number, and the old one for a
    /// removed line.
    static func inline(_ blocks: [DiffBlock], version: Int = 0) -> RenderedSide {
        var out = Builder()
        out.side.version = version
        for (index, block) in blocks.enumerated() {
            switch block {
            case .context(_, let new):
                for n in new { out.line(n.text, number: n.number) }
            case .fold(let old, _):
                out.fold(old.count, index: index)
            case .change(let removed, let added):
                out.markChange()
                for r in removed {
                    out.line(r.text, number: r.number, background: removedLine, changed: r.changed, changedColor: removedChars)
                }
                for a in added {
                    out.line(a.text, number: a.number, background: addedLine, changed: a.changed, changedColor: addedChars)
                }
            }
        }
        return out.side
    }

    private struct Builder {
        var side = RenderedSide()
        private var location = 0

        mutating func markChange() { side.changeLines.append(side.lineNumbers.count) }

        @discardableResult
        mutating func line(_ text: String, number: Int?, background: NSColor? = nil,
                           changed: [NSRange] = [], changedColor: NSColor? = nil) -> NSRange {
            let text = Self.oneLine(text)
            let length = (text as NSString).length
            side.text += text
            side.text += "\n"
            side.lineNumbers.append(number)
            // The newline too, so an empty line still gets its background.
            let range = NSRange(location: location, length: length + 1)
            if let background { side.backgrounds.append((range, background)) }
            if let changedColor {
                for r in changed where r.length > 0 && NSMaxRange(r) <= length {
                    side.spans.append((NSRange(location: location + r.location, length: r.length), changedColor))
                }
            }
            location += length + 1
            return range
        }

        mutating func fold(_ count: Int, index: Int) {
            let range = line(DiffRendering.foldText(count), number: nil, background: DiffRendering.neutralLine)
            side.folds.append((NSRange(location: range.location, length: range.length - 1), index: index))
        }

        /// A carriage return or another line separator inside a line would
        /// break it in two in the text view; each becomes one visible
        /// character of the same UTF-16 length (the changed ranges stay right).
        private static func oneLine(_ text: String) -> String {
            guard text.unicodeScalars.contains(where: { separators.contains($0) }) else { return text }
            var scalars = String.UnicodeScalarView()
            for scalar in text.unicodeScalars {
                scalars.append(separators.contains(scalar) ? (scalar == "\r" ? "\u{240D}" : "\u{FFFD}") : scalar)
            }
            return String(scalars)
        }

        private static let separators: Set<Unicode.Scalar> = ["\r", "\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"]
    }
}
