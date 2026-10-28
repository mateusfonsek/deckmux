import AppKit
import Foundation

/// Edits one JSON file through `JSONValue`, keeping everything it does not
/// change. A missing file starts as `{}`.
enum JSONEdit {
    static func edit(_ text: String?, _ change: (inout JSONValue) throws -> Void) throws -> String {
        var value = try text.map { try JSONValue(parsing: $0) } ?? .object([])
        try change(&value)
        return value.formatted(trailingNewline: text?.hasSuffix("\n") ?? true)
    }

    /// Adds or removes names in a JSON array of strings at `path`, keeping
    /// the order of the others. An array left empty is removed.
    static func setNames(_ names: [String], present: Bool, at path: [String], in value: inout JSONValue) {
        value.update(path) { current in
            var items = current?.arrayValue ?? []
            for name in names {
                let exists = items.contains { $0.stringValue == name }
                if present, !exists { items.append(.string(name)) }
                if !present { items.removeAll { $0.stringValue == name } }
            }
            return items.isEmpty ? nil : .array(items)
        }
    }
}

/// The colors a workspace can take.
enum WorkspacePalette {
    static let colors: [(name: String, hex: String)] = [
        ("Azul", "#409CFF"), ("Verde", "#2ECC87"), ("Roxo", "#A78BFA"), ("Laranja", "#FB923C"),
        ("Rosa", "#F472B6"), ("Amarelo", "#FACC15"), ("Ciano", "#22D3EE"), ("Vermelho", "#F87171"),
    ]

    static func name(of hex: String) -> String? {
        colors.first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }?.name.lowercased()
    }
}

/// Claude Code theme (`~/.claude/themes/<slug>.json`) derived from the
/// workspace color, in the same shape as the hand-written themes.
enum ClaudeTheme {
    struct RGB {
        var r: Double, g: Double, b: Double

        init(r: Double, g: Double, b: Double) { (self.r, self.g, self.b) = (r, g, b) }

        init?(hex: String) {
            let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
            self.init(r: Double((value >> 16) & 0xFF), g: Double((value >> 8) & 0xFF), b: Double(value & 0xFF))
        }

        func mixed(with other: RGB, _ amount: Double) -> RGB {
            RGB(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount, b: b + (other.b - b) * amount)
        }

        func scaled(_ factor: Double) -> RGB { RGB(r: r * factor, g: g * factor, b: b * factor) }
        func lifted(_ amount: Double) -> RGB { RGB(r: r + amount, g: g + amount, b: b + amount) }

        var css: String {
            func channel(_ v: Double) -> Int { Int(max(0, min(255, v)).rounded()) }
            return "rgb(\(channel(r)),\(channel(g)),\(channel(b)))"
        }
    }

    static let white = RGB(r: 255, g: 255, b: 255)
    static let darkSurface = RGB(r: 30, g: 34, b: 40)

    /// The theme's color keys; other keys in an existing theme are kept.
    static func overrides(for hex: String) -> [(String, String)] {
        guard let color = RGB(hex: hex) else { return [] }
        let border = color.scaled(0.7)
        let message = darkSurface.mixed(with: color, 0.15)
        return [
            ("claude", color.css),
            ("claudeShimmer", color.mixed(with: white, 0.33).css),
            ("clawd_body", color.css),
            ("promptBorder", border.css),
            ("promptBorderShimmer", color.mixed(with: white, 0.2).scaled(0.9).css),
            ("userMessageBackground", message.css),
            ("userMessageBackgroundHover", message.lifted(12).css),
        ]
    }

    static func text(updating current: String?, name: String, color: String) throws -> String {
        try JSONEdit.edit(current) { theme in
            theme.set("name", .string(name))
            if theme["base"] == nil { theme.set("base", .string("dark")) }
            for (key, value) in overrides(for: color) {
                theme.update(["overrides", key]) { _ in .string(value) }
            }
        }
    }
}

/// What the "Estado atual" table of `~/.claude/workspace.md` says about one
/// workspace.
struct WorkspaceSummary {
    var name: String
    var slug: String
    var color: String
    var mcpNames: [String]
    /// The `## ` section titles of the workspace's CLAUDE.md.
    var claudeSections: [String]

    static func sections(of claudeMd: String?) -> [String] {
        (claudeMd ?? "").split(separator: "\n").compactMap { line in
            line.hasPrefix("## ") ? line.dropFirst(3).trimmingCharacters(in: .whitespaces) : nil
        }
    }
}

/// Rewrites only the table between `<!-- workspaces:begin -->` and
/// `<!-- workspaces:end -->`. The first time, it wraps the table under
/// "## Estado atual" with those markers. Rows Deckmux does not generate are
/// kept, with "idem" in the columns of new workspaces.
enum WorkspaceGuide {
    static let begin = "<!-- workspaces:begin -->"
    static let end = "<!-- workspaces:end -->"
    private static let generatedRows = ["MCPs do workspace", "`CLAUDE.md` do workspace", "Tema"]

    /// `slugByName` maps the column names now in the file to slugs, so rows
    /// the user wrote keep their cells when a workspace is renamed.
    static func text(updating current: String?, workspaces: [WorkspaceSummary], slugByName: [String: String]) -> String? {
        guard let current else { return nil }
        var lines = current.components(separatedBy: "\n")
        let range: Range<Int>
        if let start = lines.firstIndex(of: begin), let stop = lines.firstIndex(of: end), start < stop {
            range = start..<(stop + 1)
        } else if let heading = lines.firstIndex(where: { $0.hasPrefix("## Estado atual") }),
                  let tableStart = lines[(heading + 1)...].firstIndex(where: { $0.hasPrefix("|") }) {
            var tableEnd = tableStart
            while tableEnd < lines.count, lines[tableEnd].hasPrefix("|") { tableEnd += 1 }
            range = tableStart..<tableEnd
        } else {
            return current
        }
        let oldTable = lines[range].filter { $0.hasPrefix("|") }
        let table = [begin] + makeTable(workspaces, keeping: oldTable, slugByName: slugByName) + [end]
        lines.replaceSubrange(range, with: table)
        return lines.joined(separator: "\n")
    }

    private static func cells(_ line: String) -> [String] {
        var parts = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// Same style as the hand-written table: "| | Acme |" and "|---|---|".
    private static func row(_ cells: [String]) -> String {
        "|" + cells.map { $0.isEmpty ? " " : " \($0) " }.joined(separator: "|") + "|"
    }

    private static func makeTable(_ workspaces: [WorkspaceSummary], keeping old: [String], slugByName: [String: String]) -> [String] {
        let oldHeader = old.first.map(cells) ?? []
        // Rows the user wrote, by their first cell, with cells by workspace slug.
        var kept: [(label: String, values: [String: String])] = []
        for line in old.dropFirst(2) {
            let parts = cells(line)
            guard let label = parts.first, !generatedRows.contains(label) else { continue }
            var values: [String: String] = [:]
            for (index, value) in parts.enumerated().dropFirst() where index < oldHeader.count {
                values[slugByName[oldHeader[index]] ?? oldHeader[index]] = value
            }
            kept.append((label, values))
        }

        var table = [row([""] + workspaces.map(\.name)), "|" + String(repeating: "---|", count: workspaces.count + 1)]
        table.append(row(["MCPs do workspace"] + workspaces.map { ws in
            ws.mcpNames.isEmpty ? "—" : ws.mcpNames.map { "`\($0)`" }.joined(separator: ", ")
        }))
        for keptRow in kept {
            table.append(row([keptRow.label] + workspaces.map { keptRow.values[$0.slug] ?? "idem" }))
        }
        table.append(row(["`CLAUDE.md` do workspace"] + workspaces.map { ws in
            ws.claudeSections.isEmpty ? "só título" : "título + " + ws.claudeSections.joined(separator: " + ")
        }))
        table.append(row(["Tema"] + workspaces.map { ws in
            let color = WorkspacePalette.name(of: ws.color) ?? ws.color
            return "`custom:\(ws.slug)` (\(color))"
        }))
        return table
    }
}
