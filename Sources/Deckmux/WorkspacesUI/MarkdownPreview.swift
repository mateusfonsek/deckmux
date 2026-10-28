import SwiftUI

/// Renders the Markdown a CLAUDE.md uses: headings, paragraphs, lists,
/// quotes, code blocks and rules, with inline styles (bold, code, links).
struct MarkdownPreview: View {
    let text: String

    enum Block: Hashable {
        case heading(Int, String)
        case paragraph(String)
        case bullet(Int, String)
        case numbered(String, String)
        case quote(String)
        case code(String)
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let content):
            inline(content)
                .font(level == 1 ? .title.weight(.bold) : level == 2 ? .title2.weight(.semibold) : .headline)
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let content):
            inline(content)
        case .bullet(let depth, let content):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(depth == 0 ? "•" : "◦").foregroundStyle(.secondary)
                inline(content)
            }
            .padding(.leading, CGFloat(depth) * 16 + 4)
        case .numbered(let number, let content):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number).foregroundStyle(.secondary).monospacedDigit()
                inline(content)
            }
            .padding(.leading, 4)
        case .quote(let content):
            inline(content)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3) }
        case .code(let content):
            Text(content)
                .font(.system(size: 12, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func inline(_ markdown: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: markdown, options: options) { return Text(attributed) }
        return Text(markdown)
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }

        for raw in text.components(separatedBy: "\n") {
            if var lines = code {
                if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(raw)
                    code = lines
                }
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix { $0 == " " }.count
            if line.hasPrefix("```") { flush(); code = []; continue }
            if line.isEmpty { flush(); continue }
            if let hashes = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"), line[hashes] == " " {
                flush()
                blocks.append(.heading(line.distance(from: line.startIndex, to: hashes), String(line[line.index(after: hashes)...])))
                continue
            }
            if line == "---" || line == "***" { flush(); blocks.append(.rule); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                blocks.append(.bullet(indent / 2, String(line.dropFirst(2))))
                continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.numbered(String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...])))
                continue
            }
            if line.hasPrefix("> ") { flush(); blocks.append(.quote(String(line.dropFirst(2)))); continue }
            // A continuation line of a list item belongs to it.
            if indent >= 2, case .bullet(let depth, let previous)? = blocks.last, paragraph.isEmpty {
                blocks[blocks.count - 1] = .bullet(depth, previous + " " + line)
                continue
            }
            paragraph.append(line)
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}
