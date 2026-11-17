import Foundation

/// Edits the `[mcp_servers.<name>]` tables of a Codex `config.toml`, leaving
/// every other line of the file as it was.
public enum TomlTables {
    public static func edited(_ current: String?, adding: [McpServer], removing: [String]) throws -> String? {
        var text = current ?? ""
        for name in Set(removing + adding.map(\.name)) {
            text = removingServer(name, from: text)
        }
        for server in adding {
            let block = render(server)
            if text.isEmpty {
                text = block
            } else {
                if !text.hasSuffix("\n") { text += "\n" }
                text += "\n" + block
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Takes out `[mcp_servers.<name>]` and its subtables, each up to the next
    /// header. A block at the end also takes the blank lines before it.
    static func removingServer(_ name: String, from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let own = Set([tableKey(name), tableKey(name) + ".env", tableKey(name) + ".http_headers"])
        var index = 0
        while index < lines.count {
            guard let header = header(lines[index]), own.contains(header) else { index += 1; continue }
            var end = index + 1
            while end < lines.count, !isTableStart(lines[end]) { end += 1 }
            // Comments right above the next table belong to it.
            if end < lines.count {
                while end - 1 > index, lines[end - 1].trimmingCharacters(in: .whitespaces).hasPrefix("#") { end -= 1 }
            }
            let atEnd = end == lines.count
            lines.removeSubrange(index..<end)
            if atEnd {
                while index > 0, lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.remove(at: index - 1)
                    index -= 1
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// `[table]` or `[[array of tables]]`: either ends the block above it.
    private static func isTableStart(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("[")
    }

    private static func header(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[["), let close = trimmed.firstIndex(of: "]") else { return nil }
        return trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            .split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ".")
    }

    static func tableKey(_ name: String) -> String { "mcp_servers." + key(name) }

    private static func key(_ name: String) -> String {
        let bare = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let isBare = !name.isEmpty && name.unicodeScalars.allSatisfy { $0.isASCII && bare.contains($0) }
        return isBare ? name : quoted(name)
    }

    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    static func render(_ server: McpServer) -> String {
        var out = "[\(tableKey(server.name))]\n"
        var sub: (String, [String: String])?
        switch server.transport {
        case .stdio(let command, let args, let env):
            out += "command = \(quoted(command))\n"
            out += "args = [\(args.map(quoted).joined(separator: ", "))]\n"
            if !env.isEmpty { sub = ("env", env) }
        case .http(let url, let headers):
            out += "url = \(quoted(url))\n"
            if !headers.isEmpty { sub = ("http_headers", headers) }
        }
        if let (table, values) = sub {
            out += "\n[\(tableKey(server.name)).\(table)]\n"
            for (name, value) in values.sorted(by: { $0.key < $1.key }) { out += "\(key(name)) = \(quoted(value))\n" }
        }
        return out
    }
}
