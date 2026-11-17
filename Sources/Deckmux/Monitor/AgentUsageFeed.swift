import DeckmuxAgents
import DeckmuxMonitor
import Foundation

/// The usage the Janelinha shows for one agent: a value (or the last good
/// one) and why it could not be refreshed.
@MainActor
protocol AgentUsageFeed: AnyObject {
    var onUpdate: ((Usage?, String?) -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
enum AgentUsageFeeds {
    /// The feed for `kind`, or nil when the agent has no usage source.
    static func make(for kind: AgentKind) -> AgentUsageFeed? {
        switch AgentRegistry.provider(for: kind).usageSource {
        case .claudeAccount?: ClaudeUsageFeed()
        case .codexSessions?: CodexUsageClient()
        case nil: nil
        }
    }
}

/// Claude Code's account usage, through `UsageClient`.
@MainActor
final class ClaudeUsageFeed: AgentUsageFeed {
    private let client = UsageClient()
    var onUpdate: ((Usage?, String?) -> Void)?

    init() {
        client.onUpdate = { [weak self] usage, failure in self?.onUpdate?(usage, Self.problem(usage, failure)) }
    }

    func start() { client.start() }
    func stop() { client.stop() }

    static func problem(_ usage: Usage?, _ failure: UsageClient.Failure?) -> String? {
        switch failure {
        case nil: nil
        case .noToken?, .unauthorized?: "Uso: faça /login no Claude Code"
        case .keychainDenied?: "Uso: acesso ao Keychain negado"
        case .malformed?: "Uso indisponível"
        case .network?, .rateLimited?:
            usage.map { "⚠ \(AgentStatusItem.ago($0.fetchedAt, now: Date()))" } ?? "Uso indisponível"
        }
    }
}
