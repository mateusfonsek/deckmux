import DeckmuxMonitor
import Foundation

/// Codex's usage from its newest session files, every 2 min while the
/// Janelinha is on. Files only: no token, no network.
@MainActor
final class CodexUsageClient: AgentUsageFeed {
    static let interval: TimeInterval = 120
    private var timer: Timer?
    var onUpdate: ((Usage?, String?) -> Void)?

    private var codexHome: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? ConfigPaths.home.appendingPathComponent(".codex")
    }

    func start() {
        read()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func read() {
        let home = codexHome
        Task.detached(priority: .utility) {
            let usage = Self.latestUsage(codexHome: home)
            await MainActor.run { [weak self] in
                self?.onUpdate?(usage, usage == nil ? "Uso: use o Codex uma vez para aparecer aqui" : nil)
            }
        }
    }

    /// The newest session that has limits (a fresh one may have none yet).
    nonisolated static func latestUsage(codexHome: URL) -> Usage? {
        guard let file = CodexUsage.latestSessionFile(codexHome: codexHome),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return CodexUsage.parse(jsonl: text, fetchedAt: modified)
    }
}
