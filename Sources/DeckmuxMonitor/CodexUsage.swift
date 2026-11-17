import Foundation

/// Codex's account usage, read from its own session files: every
/// `token_count` event carries the latest `rate_limits` (primary = the
/// 5-hour window, secondary = the weekly one). Local files only, no network.
public enum CodexUsage {
    public static func parse(jsonl: String, fetchedAt: Date) -> Usage? {
        for line in jsonl.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            let five = window(limits["primary"]), week = window(limits["secondary"])
            guard five != nil || week != nil else { continue }
            return Usage(fiveHour: five, sevenDay: week, fetchedAt: fetchedAt)
        }
        return nil
    }

    private static func window(_ value: Any?) -> UsageWindow? {
        guard let value = value as? [String: Any], let percent = (value["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let resets = (value["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return UsageWindow(percent: percent, resetsAt: resets)
    }

    /// The session file Codex wrote last, under `<codexHome>/sessions`.
    public static func latestSessionFile(codexHome: URL) -> URL? {
        let sessions = codexHome.appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: sessions.path),
              let files = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var newest: (URL, Date)?
        for case let file as URL in files where file.pathExtension == "jsonl" {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if newest == nil || date > newest!.1 { newest = (file, date) }
        }
        return newest?.0
    }
}
