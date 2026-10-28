import Foundation

/// A subagent of a conversation, from `agent-<id>.meta.json` and the tail of
/// its `agent-<id>.jsonl`.
public struct SubagentInfo: Equatable, Identifiable, Sendable {
    public var id: String
    public var agentType: String
    public var description: String
    public var model: String?
    /// The .meta.json modification date.
    public var startedAt: Date
    /// The .jsonl modification date (or startedAt without one).
    public var updatedAt: Date
    public var isFinished: Bool

    public init(id: String, agentType: String, description: String, model: String?, startedAt: Date, updatedAt: Date, isFinished: Bool) {
        self.id = id
        self.agentType = agentType
        self.description = description
        self.model = model
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.isFinished = isFinished
    }
}

public enum SubagentReader {
    /// Only the end of a transcript is read, never the whole file.
    public static let tailBytes = 16 * 1024

    /// The folder's agents not older than `maxAge` (by updatedAt), newest first, at most `limit`.
    public static func read(folder: URL, now: Date, maxAge: TimeInterval = 3600, limit: Int = 5) -> [SubagentInfo] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        let agents = names.compactMap { name -> SubagentInfo? in
            guard name.hasPrefix("agent-"), name.hasSuffix(".meta.json") else { return nil }
            let id = String(name.dropFirst("agent-".count).dropLast(".meta.json".count))
            let meta = folder.appendingPathComponent(name)
            guard let data = fm.contents(atPath: meta.path),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            let transcript = folder.appendingPathComponent("agent-\(id).jsonl")
            let startedAt = modificationDate(meta) ?? now
            let updatedAt = modificationDate(transcript) ?? startedAt
            guard now.timeIntervalSince(updatedAt) <= maxAge else { return nil }
            return SubagentInfo(id: id,
                                agentType: object["agentType"] as? String ?? "agente",
                                description: object["description"] as? String ?? "",
                                model: object["model"] as? String,
                                startedAt: startedAt, updatedAt: updatedAt,
                                isFinished: isFinished(transcript: transcript))
        }
        return Array(agents.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Whether the transcript ends: every JSONL line ends in "\n", so bytes
    /// after the last "\n" are a line still being written (running), and
    /// otherwise the last complete line decides.
    public static func isFinished(transcript url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return false }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else { return false }
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return false }
        if lastNewline < data.index(before: data.endIndex) { return false }   // a partial line after it
        // The last two complete lines.
        var lines: [String] = []
        var end = lastNewline
        while lines.count < 2 {
            let body = data[data.startIndex..<end]
            let start = body.lastIndex(of: UInt8(ascii: "\n")).map { data.index(after: $0) } ?? body.startIndex
            guard let line = String(data: data[start..<end], encoding: .utf8) else { return false }
            lines.insert(line, at: 0)
            if start == data.startIndex { break }
            end = data.index(before: start)
        }
        return isFinished(lastLines: lines)
    }

    /// Finished when one of the last lines is the agent's `SubagentHandback`
    /// call (how subagents report back and end), or the last line is an
    /// assistant message with no `tool_use` block (an agent without a handback).
    static func isFinished(lastLines: [String]) -> Bool {
        guard let last = lastLines.last else { return false }
        if lastLines.contains(where: { line in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return false }
            return content.contains { $0["type"] as? String == "tool_use" && $0["name"] as? String == "SubagentHandback" }
        }) { return true }
        return isFinished(lastLine: last)
    }

    /// An assistant message with no `tool_use` block is the agent's last word.
    static func isFinished(lastLine: String) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(lastLine.utf8))) as? [String: Any],
              object["type"] as? String == "assistant" else { return false }
        let message = object["message"] as? [String: Any]
        guard let content = message?["content"] as? [[String: Any]] else { return true }   // a plain string is text
        return !content.contains { $0["type"] as? String == "tool_use" }
    }
}
